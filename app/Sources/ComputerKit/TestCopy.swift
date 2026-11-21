import Foundation

/// A throwaway test copy of pi², which an agent may work, not only look at, once the person has allowed test copies in
/// its settings (#146).
///
/// The engine lets such an agent use any app whose bundle id begins `dev.pi2.app.test`. An id is only a name, though,
/// and any app can take it, so before acting this checks the bundle that is running under it, and calls it a test copy
/// only when it is what `scripts/test-copy` makes:
///
/// - its bundle id is `dev.pi2.app.<suffix>`, with a suffix beginning `test`;
/// - it sits at `<checkout>/app/build/test-copies/<suffix>/<name>.app`;
/// - it is a development build of that same checkout: it carries no engine of its own and its `PI2EngineMain` names
///   `<checkout>/engine/src/main.ts`, as `DevelopmentBuild` in the app tells one.
///
/// A development build never uses the usual data folder or Keychain service, so a copy like this cannot show the real
/// agents' requests, and approving something in it approves only its own. A copy of a release build carries its own
/// engine and can run on the usual data folder, so it never counts, whatever it is called or wherever it is; nor do
/// pi² itself, the development build as built (`dev.pi2.app.dev`), or another app under a similar id.
public enum TestCopy {
    static let prefix = "dev.pi2.app."

    /// Whether `bundleID` is named as a test copy is; the engine's `isTestCopy`. Not enough on its own to act.
    public static func hasTestCopyID(_ bundleID: String) -> Bool {
        bundleID.lowercased().hasPrefix(prefix + "test")
    }

    /// The folder a test copy's app polls for window requests (`TestCopyControl`), in the data folder its bundle id
    /// names — the same derivation `DevelopmentBuild` in the app makes of it. Nil for an id that is not a test
    /// copy's or whose suffix is not one. The folder itself need not exist; `exposeParkedCopy` checks it.
    public static func controlFolder(bundleID: String) -> URL? {
        let id = bundleID.lowercased()
        guard hasTestCopyID(id) else { return nil }
        let suffix = String(id.dropFirst(prefix.count))
        guard suffix.range(of: #"^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$"#, options: .regularExpression) != nil else { return nil }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("pi2-\(suffix)", isDirectory: true).appendingPathComponent("test-copy-control", isDirectory: true)
    }

    /// Whether the bundle at `bundleURL`, running as `bundleID`, is a throwaway test copy of a development build.
    public static func isThrowaway(bundleURL: URL, bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        guard hasTestCopyID(id) else { return false }
        let suffix = String(id.dropFirst(prefix.count))
        let bundle = bundleURL.resolvingSymlinksInPath().standardizedFileURL
        guard bundle.pathExtension == "app" else { return false }
        // <checkout>/app/build/test-copies/<suffix>/<name>.app
        let folder = bundle.deletingLastPathComponent()
        let copies = folder.deletingLastPathComponent()
        let build = copies.deletingLastPathComponent()
        let app = build.deletingLastPathComponent()
        let checkout = app.deletingLastPathComponent()
        guard folder.lastPathComponent == suffix, copies.lastPathComponent == "test-copies", build.lastPathComponent == "build",
              app.lastPathComponent == "app", checkout.path != "/" else { return false }
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        guard let info = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist")),
              (info["CFBundleIdentifier"] as? String)?.lowercased() == id else { return false }
        // A development build: no engine inside, and the one it runs is this checkout's.
        guard !FileManager.default.fileExists(atPath: contents.appendingPathComponent("Resources/engine").path),
              let engine = info["PI2EngineMain"] as? String, !engine.isEmpty else { return false }
        let expected = checkout.appendingPathComponent("engine/src/main.ts")
        return URL(fileURLWithPath: engine).resolvingSymlinksInPath().standardizedFileURL.path == expected.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
