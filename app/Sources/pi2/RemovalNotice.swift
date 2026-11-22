import AppKit
import SwiftUI

// What the update to projects tells the person, over the Dashboard, a project's hub or the page that makes the first
// project (#716; docs/projects.md, 9.8 and 10.1). The engine moves everything into projects at its first start after the
// update, once it has made a copy of the data (#715), and says so in the `projects` event's `carryOver`:
// `removalBackup` once the copy is made, `removalFailed` while the copy or the move could not be done. The first is told
// once, for each copy: which one was told is the app's own preference. The second stays until it is gone. A copy that
// took an agent's variables but could not copy their values says so too, with Try Again, until they are copied.

/// Which copy of the data the person has been told of, by its time: the app's own, in its preferences (10.1).
enum RemovalNoticeSeen {
    static let key = "removal.noticeSeen"

    static func told(_ at: Double) -> Bool { UserDefaults.standard.double(forKey: key) == at }
    static func tell(_ at: Double) { UserDefaults.standard.set(at, forKey: key) }
}

struct RemovalNotice: View {
    let model: AppModel
    /// Set when the person dismisses the notice, so that it goes at once.
    @State private var dismissed: Double?
    @State private var retrying = false
    @State private var retryProblem: String?
    private var engine: EngineClient { model.engine }

    var body: some View {
        let carry = shown
        VStack(spacing: 0) {
            if let reason = carry.failed {
                failed(reason)
            } else if let backup = carry.backup, dismissed != backup.at, !RemovalNoticeSeen.told(backup.at) {
                // A data folder that had nothing to move, as a new installation has, is not told of it.
                if hadNothing {
                    Color.clear.frame(height: 0).onAppear { RemovalNoticeSeen.tell(backup.at) }
                } else {
                    told(backup)
                }
            }
            if !carry.pending.isEmpty { pending(carry.pending) }
        }
    }

    /// What the engine said, or a development build's stand-in for it (`RemovalNoticePreview`).
    private var shown: (backup: CarryOverState.RemovalBackup?, failed: String?, pending: [CarryOverState.Pending]) {
        let carry = engine.projectStore.carryOver
        #if PI2_DEVELOPMENT
        if let preview = RemovalNoticePreview.asked { return (preview.backup, preview.failed, carry?.secretsPending ?? []) }
        #endif
        return (carry?.removalBackup, carry?.removalFailed, carry?.secretsPending ?? [])
    }

    /// Whether the data folder had nothing the update could have moved: no conversation, listed or archived, and no
    /// project. Only once the engine has listed both.
    private var hadNothing: Bool {
        engine.hasLoadedLibrary && engine.projectStore.loaded && engine.conversations.isEmpty && engine.archived.isEmpty
            && engine.projects.isEmpty
    }

    /// Once after the update: that pi² works by projects only now, where the copy of the data as it was is, and that the
    /// update cannot be switched back.
    private func told(_ backup: CarryOverState.RemovalBackup) -> some View {
        let path = (backup.path as NSString).abbreviatingWithTildeInPath
        return banner(tone: Theme.acc) {
            Label("pi² now works by projects", systemImage: "folder")
                .font(.callout.weight(.semibold))
            // No fixedSize on these texts: inside the window's top inset it stopped the whole window drawing (EngineTrouble).
            Text("Your conversations are in projects by their folder, each project with an orchestrator, and your agents are templates under Shared. The old agents and conversations screens are gone, and this cannot be switched back.")
                .font(.callout).foregroundStyle(Theme.tx2)
            Text("A copy of your data as it was before the update is at \(path). It holds no keys or sign-ins, which stay in the Keychain. Restoring it in Settings › Storage replaces everything done since.")
                .font(.callout).foregroundStyle(Theme.tx2)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Button("Show in Finder") { reveal(backup.path) }
                    .buttonStyle(.piSecondary)
                    .help("Show the copy of your data in Finder")
                Button("OK") {
                    RemovalNoticeSeen.tell(backup.at)
                    dismissed = backup.at
                }
                .buttonStyle(.piPrimary)
                .help("Put this notice away. It is not shown again.")
                Spacer(minLength: 0)
            }
        }
    }

    /// While the update could not make its copy of the data, or could not move everything: why, until it has.
    private func failed(_ reason: String) -> some View {
        banner(tone: Theme.bad) {
            Label("pi² could not move everything into projects", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Theme.bad)
            Text(reason)
                .font(.callout).foregroundStyle(Theme.tx2)
                .textSelection(.enabled)
            Text("Nothing is moved before a copy of your data has been made. pi² tries again the next time its engine starts; engine.log says more.")
                .font(.callout).foregroundStyle(Theme.tx2)
            HStack(spacing: 8) {
                Button("Show engine.log in Finder") { reveal(engine.dataFolder.appendingPathComponent("engine.log").path) }
                    .buttonStyle(.piSecondary)
                Spacer(minLength: 0)
            }
        }
    }

    /// Copies of agents that took their variables, whose values could not be copied from the Keychain yet (9.5).
    private func pending(_ items: [CarryOverState.Pending]) -> some View {
        banner(tone: Theme.warn) {
            ForEach(items, id: \.copy) { item in
                Text("\(item.variables.count == 1 ? "1 of \(item.name)’s variables has" : "\(item.variables.count) of \(item.name)’s variables have") not been copied from the agent it was made from, in \(item.project).\(item.error.map { " \($0)" } ?? "")")
                    .font(.callout).foregroundStyle(Theme.warn)
            }
            if let retryProblem { Text(retryProblem).font(.callout).foregroundStyle(Theme.bad) }
            HStack(spacing: 8) {
                Button("Try Again") { retrySecrets() }
                    .buttonStyle(.piSecondary)
                    .disabled(retrying || engine.status != .connected)
                    .help("Copy the variables' values again")
                Spacer(minLength: 0)
            }
        }
    }

    private func banner<Content: View>(tone: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel(fill: tone.opacity(0.08), border: tone.opacity(0.35))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Theme.window)
    }

    /// Shows a path in Finder; a test copy writes down what it would have shown instead (#451).
    private func reveal(_ path: String) {
        if let file = TestCopyRecord.fileLinks(engine: engine) {
            TestCopyRecord.append(["action": "show", "path": path, "from": "removal-notice"], to: file)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func retrySecrets() {
        retrying = true
        retryProblem = nil
        Task {
            defer { retrying = false }
            do {
                _ = try await engine.call("projects.retrySecrets")
            } catch {
                retryProblem = error.localizedDescription
            }
        }
    }
}

#if PI2_DEVELOPMENT
/// A stand-in for what the engine says of the update, so that a test copy can show both forms of the notice without
/// an engine that makes them: the copy's own preference, set before launch, which only a development build reads.
///
///     defaults write dev.pi2.app.test-7 removal-notice -string 'backup'
///     defaults write dev.pi2.app.test-7 removal-notice -string 'failed'
///
/// `backup` tells of a copy of the data made at launch, in the copy's own data folder's `backups/`, once, as the update
/// does; `failed` shows the banner of an update that could not make its copy. See docs/development.md.
@MainActor
enum RemovalNoticePreview {
    static let asked: (backup: CarryOverState.RemovalBackup?, failed: String?)? = {
        switch UserDefaults.standard.string(forKey: "removal-notice") {
        case "backup":
            let home = DevelopmentBuild.defaults(bundleID: Bundle.main.bundleIdentifier, applicationSupport: DevelopmentBuild.usualHome.deletingLastPathComponent()).home
            return (CarryOverState.RemovalBackup(path: home.appendingPathComponent("backups/pi2-backup-before-projects").path, at: Date().timeIntervalSince1970 * 1000), nil)
        case "failed":
            return (nil, "The copy of the data could not be made: there is not enough room on the disk (a stand-in reason).")
        default:
            return nil
        }
    }()
}
#endif
