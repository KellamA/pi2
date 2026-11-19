import SwiftUI

#if PI2_DEVELOPMENT
/// Like PI2_SHOW and the file-driven performance probe, this is part of development builds only.
/// The launch switch isn't enough: require the bundle and data folder that scripts/test-copy makes.
@MainActor
private struct TestCopyControl: NSViewRepresentable {
    let model: AppModel
    let folder: URL

    static func folder(for model: AppModel) -> URL? {
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
              model.engine.dataFolder.standardizedFileURL.path == own.home.standardizedFileURL.path,
              !DevelopmentBuild.isSameFolder(own.home.path, as: DevelopmentBuild.usualHome) else { return nil }
        return own.home.appendingPathComponent("test-copy-control", isDirectory: true)
    }

    func makeNSView(context: Context) -> Control { Control(model: model, folder: folder) }
    func updateNSView(_ view: Control, context: Context) {}
    static func dismantleNSView(_ view: Control, coordinator: ()) { view.stop() }

    final class Control: NSView {
        private struct Request: Decodable {
            let pid: Int32
            let command: String
            let id: Int?
            let width: Int?
            let height: Int?
            let smallest: Bool?
        }

        let model: AppModel
        let folder: URL
        private var timer: Timer?

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
            for name in names.sorted() where name.hasPrefix("request-") {
                let dir = folder.appendingPathComponent(name, isDirectory: true)
                guard isDirectory(dir) else { continue }
                let response = dir.appendingPathComponent("response.json")
                let request = dir.appendingPathComponent("request.json")
                guard !FileManager.default.fileExists(atPath: response.path),
                      let data = try? Data(contentsOf: request),
                      let asked = try? JSONDecoder().decode(Request.self, from: data), asked.pid == getpid() else { continue }
                let result = apply(asked, to: window)
                if let json = try? JSONEncoder().encode(result) { try? json.write(to: response, options: .atomic) }
            }
        }

        private func apply(_ request: Request, to window: NSWindow) -> [String: String] {
            switch request.command {
            case "show":
                guard let id = request.id, model.engine.conversations.contains(where: { $0.id == id }) || model.isArchived(id) else {
                    return ["error": "no conversation #\(request.id ?? 0) in the copy's library"]
                }
                model.selection = .conversation(id)
                return ["result": "Showing conversation #\(id)"]
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
