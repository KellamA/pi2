import SwiftUI
import WindowKit

#if PI2_DEVELOPMENT
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
            let width: Int?
            let height: Int?
            let smallest: Bool?
            let paths: [String]?
        }

        let model: AppModel
        let folder: URL
        private var timer: Timer?
        /// `show` requests answered once the page has drawn the conversation, or after `limit`: the request's folder,
        /// the conversation, and how many drawings the page had made when it was asked.
        private var waiting: [(dir: URL, id: Int, after: Int, until: Date)] = []
        /// `show` requests for a project's hub, answered once the hub has drawn what was asked, or after `limit`.
        private var hubWaiting: [(dir: URL, asked: ProjectCopyView, project: String, until: Date)] = []
        /// The project `PI2_SHOW` named at launch, until it comes in the `projects` event and is shown, and how long to
        /// wait for an agent's conversation of it named there.
        private var launchProject: ProjectCopyView?
        private var launchUntil = Date.distantFuture
        /// Within test-copy's own thirty seconds, so it hears why rather than that nothing answered.
        private static let limit: TimeInterval = 20

        init(model: AppModel, folder: URL) {
            self.model = model
            self.folder = folder
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
                if let drawn = hubDrawn(wait.asked, project: wait.project) {
                    answer(wait.dir, ["result": drawn])
                } else if Date() >= wait.until {
                    answer(wait.dir, ["result": "Showing the project, though the hub had not drawn it after \(Int(Self.limit)) seconds"])
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
                    if let conversation { model.openAgent(conversation, in: id) }
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
            guard engine.projectsPreview else { return nil }
            let live = engine.projects.filter { $0.deletedAt == nil }
            return (live.first { $0.id == asked } ?? live.first { $0.name.lowercased() == asked.lowercased() })?.id
        }

        /// Shows the hub `view` asks for: its project, its tab, its fold and, when it names an agent, that agent's
        /// conversation in place of the board (#473). Nil when the answer is to wait for the hub to draw it. A fold alone
        /// applies to the project shown. The Dashboard is a later issue's, and is only recorded.
        private func showProject(_ view: ProjectCopyView, dir: URL) -> [String: String]? {
            if view.show == "dashboard" {
                // The sidebar's row is selected (#470); what it opens is the Dashboard's issue (#481).
                guard model.engine.projectsPreview else { return ["error": "the copy has the projects preview off; fill it with --project first"] }
                model.selection = .dashboard
                return ["result": "Selected the Dashboard's row; the Dashboard is not drawn yet"]
            }
            let fold = view.hub.flatMap { HubFold(rawValue: $0.rawValue) }
            let id: String
            if let project = view.project {
                guard let found = projectID(project) else {
                    return ["error": model.engine.projectsPreview ? "no project called \(project) in the copy" : "the copy has the projects preview off; fill it with --project first"]
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
            model.showProject(id, tab: view.tab.flatMap { HubTab(rawValue: $0.rawValue) }, fold: fold)
            if let conversation { model.openAgent(conversation, in: id) }
            hubWaiting.append((dir, view, id, Date().addingTimeInterval(Self.limit)))
            return nil
        }

        /// What to answer once the hub has drawn the project, with its tab and fold, and the orchestrator's conversation
        /// when its panel shows it; nil until then.
        private func hubDrawn(_ asked: ProjectCopyView, project: String) -> String? {
            let fold = model.hubs.fold(project)
            guard let drawn = HubDrawn.current, drawn.project == project, drawn.tab == model.hubs.tab(project),
                  drawn.fold == fold.shown(narrow: drawn.narrow, agent: drawn.agent != nil),
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
                return "; the conversation with \(who)\(title) in place of the board"
            } ?? (asked.agent.map { "; no conversation of \($0) is in place of the board" } ?? "")
            return "Showing project “\(name)”, \(drawn.tab.title), \(words), drawn\(agent)"
        }

        /// The answer to a request, or nil when it is to wait.
        private func apply(_ request: Request, to window: NSWindow, dir: URL) -> [String: String]? {
            switch request.command {
            case "choose":
                guard let paths = request.paths else { return ["error": "missing panel answer"] }
                return TestCopyPanels.choose(paths)
            case "show":
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
                guard let id = request.id, model.engine.conversations.contains(where: { $0.id == id }) || model.isArchived(id) else {
                    return ["error": "no conversation #\(request.id ?? 0) in the copy's library"]
                }
                // Moving focus to another visible pane does not redraw its transcript. A pane kept in the layout
                // behind Inbox or Chat, on the other hand, needs to draw again when it comes back on screen.
                let alreadyShown = model.mode == .chat ? model.chats.selection == id
                    : model.showsWorkspace && model.workspace.panes.contains { $0.conversation == id }
                let before = TranscriptDrawn.drawings[id]
                model.selection = .conversation(id)
                if alreadyShown, before != nil { return ["result": "Showing conversation #\(id), drawn"] }
                waiting.append((dir, id, before ?? 0, Date().addingTimeInterval(Self.limit)))
                return nil
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
