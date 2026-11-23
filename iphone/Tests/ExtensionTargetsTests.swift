import Foundation
import Testing

/// The three app extensions are built into the app (docs/iphone-app.md, "The extensions"), each with its bundle id
/// under the app's (docs/iphone.md 9.1), its extension point, and the app's version: a version that differs from the
/// app's is refused at upload, and an extension point that is wrong is never loaded.
struct ExtensionTargetsTests {
    private static let expected: [(name: String, id: String, point: String)] = [
        ("NotificationService", "dev.pi2.ios.notifications", "com.apple.usernotifications.service"),
        ("Widgets", "dev.pi2.ios.widgets", "com.apple.widgetkit-extension"),
        ("ShareExtension", "dev.pi2.ios.share", "com.apple.share-services"),
    ]

    @Test func theAppCarriesItsThreeExtensions() throws {
        let plugIns = try #require(Bundle.main.builtInPlugInsURL, "the app has a PlugIns folder")
        let found = try FileManager.default.contentsOfDirectory(atPath: plugIns.path).filter { $0.hasSuffix(".appex") }
        #expect(found.sorted() == Self.expected.map { "\($0.name).appex" }.sorted())

        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        #expect(Bundle.main.bundleIdentifier == "dev.pi2.ios")
        for extensionTarget in Self.expected {
            let bundle = try #require(Bundle(url: plugIns.appending(path: "\(extensionTarget.name).appex")))
            #expect(bundle.bundleIdentifier == extensionTarget.id)
            let info = try #require(bundle.object(forInfoDictionaryKey: "NSExtension") as? [String: Any])
            #expect(info["NSExtensionPointIdentifier"] as? String == extensionTarget.point)
            #expect(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == appVersion)
            #expect(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String == appBuild)
        }
    }
}
