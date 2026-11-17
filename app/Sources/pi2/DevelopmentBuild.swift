import Foundation

/// A development build (`app/build.sh` without `release`) keeps apart from the installed pi². Its bundle id is
/// `dev.pi2.app.dev`, so macOS gives it preferences and permissions of its own, and it uses a data folder and a
/// Keychain service of its own, named after its bundle id, unless `PI2_HOME` and `PI2_KEYCHAIN_SERVICE` name others.
/// A copy with another bundle id, such as a throwaway test copy `dev.pi2.app.test-7`, gets its own in turn
/// (`pi2-test-7`, `dev.pi2.credentials.test-7`).
///
/// It never uses the usual data folder or the usual Keychain service, even when the environment names them. That is
/// mostly not a choice: every command an agent of the installed pi² runs inherits its engine's environment, which
/// names the usual data folder, and `open` passes that on to the app it opens. A development build that took it
/// would open the installed copy's conversations and talk to its engine.
///
/// A release build carries its own engine and keeps the usual data folder and Keychain service, as before.
enum DevelopmentBuild {
    /// Whether this is a development build: one that runs its engine from a checkout instead of carrying its own.
    /// Decided by what the bundle holds rather than by how the code was compiled, so a build that cannot find an
    /// engine inside itself counts as one and never falls back to the usual data folder.
    @MainActor static var isDevelopment: Bool { !EngineClient.isSelfContained }

    static let usualKeychainService = "dev.pi2.credentials"

    /// The data folder pi² uses when `PI2_HOME` names none.
    static var usualHome: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("pi2", isDirectory: true)
    }

    /// What names a development build's data folder and Keychain service: the part of its bundle id after
    /// `dev.pi2.app.`, in lower case. `dev` for any other bundle id, including `dev.pi2.app` itself, so a development
    /// build given the release's id still keeps apart.
    static func suffix(bundleID: String?) -> String {
        let prefix = "dev.pi2.app."
        guard let id = bundleID?.lowercased(), id.hasPrefix(prefix) else { return "dev" }
        let rest = String(id.dropFirst(prefix.count))
        let allowed = CharacterSet.lowercaseLetters.union(.decimalDigits).union(CharacterSet(charactersIn: "-."))
        guard !rest.isEmpty, rest.unicodeScalars.allSatisfy({ $0.isASCII && allowed.contains($0) }),
              !rest.hasPrefix("."), !rest.contains("..") else { return "dev" }
        return rest
    }

    /// The data folder and Keychain service of a development build with this bundle id, when the environment names
    /// none: `pi2-<suffix>` beside the usual `pi2` folder, and `dev.pi2.credentials.<suffix>`.
    static func defaults(bundleID: String?, applicationSupport: URL) -> (home: URL, keychainService: String) {
        let suffix = suffix(bundleID: bundleID)
        return (applicationSupport.appendingPathComponent("pi2-\(suffix)", isDirectory: true), "\(usualKeychainService).\(suffix)")
    }

    /// Whether `path` is the folder `usual`, however it is written: with a trailing slash, through a symbolic link,
    /// or in another case (the disk ignores case).
    static func isSameFolder(_ path: String, as usual: URL) -> Bool {
        func canonical(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path.lowercased() }
        return canonical(URL(fileURLWithPath: path, isDirectory: true)) == canonical(usual)
    }

    /// In a development build, sets `PI2_HOME` and `PI2_KEYCHAIN_SERVICE` in this process's environment to the
    /// build's own wherever the environment names none, or names the usual ones. Called first thing, so that everything
    /// after it (the data folder the app opens, the browser's store, every engine the app starts, which inherits the
    /// environment) sees them. Returns what it put aside, for app.log, or nil.
    @MainActor @discardableResult
    static func applyDefaults() -> String? {
        guard isDevelopment else { return nil }
        let own = defaults(bundleID: Bundle.main.bundleIdentifier, applicationSupport: usualHome.deletingLastPathComponent())
        let environment = ProcessInfo.processInfo.environment
        var setAside: [String] = []
        // An empty value counts as none: the engine would take it as a data folder or a service named "".
        if let home = environment["PI2_HOME"], !home.isEmpty {
            if isSameFolder(home, as: usualHome) {
                setAside.append("PI2_HOME named the usual data folder")
                setenv("PI2_HOME", own.home.path, 1)
            }
        } else {
            setenv("PI2_HOME", own.home.path, 1)
        }
        if let service = environment["PI2_KEYCHAIN_SERVICE"], !service.isEmpty {
            if service == usualKeychainService {
                setAside.append("PI2_KEYCHAIN_SERVICE named the usual Keychain service")
                setenv("PI2_KEYCHAIN_SERVICE", own.keychainService, 1)
            }
        } else {
            setenv("PI2_KEYCHAIN_SERVICE", own.keychainService, 1)
        }
        guard !setAside.isEmpty else { return nil }
        return "development build: \(setAside.joined(separator: " and ")), which a development build never uses; using \(own.home.path) and \(own.keychainService) instead"
    }
}
