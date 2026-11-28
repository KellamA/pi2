import Foundation

/// The Keychain access group the app shares with its notification service extension (docs/iphone.md 3.2, #682): the
/// group `keychain-access-groups` in both entitlements files gives them, with the team's prefix, which only the build
/// knows. `PI2KeychainAccessGroup` in the app's and the extension's Info.plist holds it, Xcode having expanded
/// `$(AppIdentifierPrefix)group.dev.pi2.ios` while building each bundle; this reads that bundle's own copy.
///
/// It is nil when no prefix was expanded: an unsigned build (the simulator, which keeps the phone's items in a file,
/// `SimulatorKeyFile`, and has no Keychain at all), or a profile that left it out. Nothing names a group then, which is
/// what the app did before #682: an item marked `shared` goes in the app's own group, which the extension cannot read,
/// and the build that has no prefix is one that could not read the Keychain anyway.
enum KeychainGroup {
    static let id: String? = group(from: Bundle.main.object(forInfoDictionaryKey: "PI2KeychainAccessGroup") as? String)

    /// The group an Info.plist value names, or nil when the build put no team's prefix in front of it: ten capital
    /// letters or digits and a dot, as `$(AppIdentifierPrefix)` expands to in a signed build. A value that is empty, or
    /// still the literal `$(AppIdentifierPrefix)`, is one no Keychain call could use, so it names no group.
    static func group(from value: String?) -> String? {
        guard let value,
              value.range(of: #"^[A-Z0-9]{10}\.[A-Za-z0-9.-]+$"#, options: .regularExpression) != nil
        else { return nil }
        return value
    }
}
