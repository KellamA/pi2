import Sparkle
import SwiftUI

/// Updates, through Sparkle. Only a self-contained build that was given a feed and a key checks for them: a
/// development build runs from its source folder and must never be replaced by a download.
///
/// Nothing is checked until the person agrees. Sparkle asks on the second launch whether to check automatically, and
/// Settings › General can change the answer later. A check sends the app's version and the macOS version, nothing else.
@MainActor
final class Updates: NSObject, SPUUpdaterDelegate {
    static let shared = Updates()

    private var controller: SPUStandardUpdaterController?
    private weak var engine: EngineClient?

    var updater: SPUUpdater? { controller?.updater }

    /// Whether this build can update itself.
    static var supported: Bool {
        EngineClient.isSelfContained
            && Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
            && Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil
    }

    func start(engine: EngineClient) {
        self.engine = engine
        guard controller == nil, Self.supported else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// Sparkle quits the app next, to replace it. The engine runs Node and the engine's files from inside the app,
    /// so it is stopped first.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        MainActor.assumeIsolated {
            engine?.prepareForUpdate()
            Self.closeSheets()
            // While a sheet is open (the welcome, the command palette, a confirmation) macOS ignores a request to quit,
            // and SwiftUI puts a closed sheet back before Sparkle's request arrives. That would leave the update
            // waiting and the engine stopped. So if the app is still here shortly after, close them and quit at once.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                Self.closeSheets()
                NSApp.terminate(nil)
            }
        }
    }

    private static func closeSheets() {
        for window in NSApp.windows {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
        }
    }
}

/// "Check for Updates…", in the app menu.
struct CheckForUpdatesButton: View {
    var body: some View {
        Button("Check for Updates…") { Updates.shared.checkForUpdates() }
            .disabled(!Updates.supported)
    }
}

/// The Updates section of Settings › General.
struct UpdateSettings: View {
    @State private var automaticChecks = Updates.shared.updater?.automaticallyChecksForUpdates ?? false
    @State private var automaticInstall = Updates.shared.updater?.automaticallyDownloadsUpdates ?? false

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        Section {
            if let updater = Updates.shared.updater {
                Toggle("Check for updates automatically", isOn: $automaticChecks)
                    .onChange(of: automaticChecks) { _, on in updater.automaticallyChecksForUpdates = on }
                Toggle("Download and install them automatically", isOn: $automaticInstall)
                    .disabled(!automaticChecks)
                    .onChange(of: automaticInstall) { _, on in updater.automaticallyDownloadsUpdates = on }
                LabeledContent(version) {
                    Button("Check Now") { Updates.shared.checkForUpdates() }
                }
            } else {
                LabeledContent(version) { EmptyView() }
            }
        } header: {
            Text("Updates")
        } footer: {
            Text(Updates.shared.updater != nil
                ? "A check asks GitHub for the newest release and sends only the app's version and your macOS version. Updates are signed, and pi² refuses one that is not. Running agents stop for the update and pick up where they were."
                : "This build does not update itself. A development build updates from its source folder: pull, then build again.").formFooter()
        }
    }
}
