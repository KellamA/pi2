import Foundation

/// What the first screen says about this build: its version, and whether it is a debug build. The version is the
/// project's MARKETING_VERSION and CURRENT_PROJECT_VERSION, read back from the bundle's Info.plist.
enum BuildInfo {
    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    static var isDebug: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    static var line: String {
        isDebug ? "Version \(version), debug build" : "Version \(version)"
    }
}
