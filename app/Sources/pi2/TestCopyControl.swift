import SwiftUI

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

        // The record stays for a script that reads it; `ProjectLaunch` applies the same view to the window.
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
                        // The sidebar shows it (#470); the hub, once it is built, reads the same state (#471).
                        if let why = ProjectLaunch.apply(view, to: model) { return ["error": "recorded, but not shown: \(why)"] }
                        return ["result": "Showing \(view.show ?? "hub fold")\(view.hub.map { " (\($0.rawValue))" } ?? "")"]
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
