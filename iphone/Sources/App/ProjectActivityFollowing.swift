
import EngineKit
import Foundation
import Observation
import os
import PiModels

/// What the app asks of ActivityKit for a project's Live Activity (`ProjectActivities`, docs/iphone-app.md, "The Live
/// Activity"), behind a protocol so that a test stands in for iOS.
@MainActor
protocol ProjectActivityControl {
    var areAllowed: Bool { get }
    /// The numbers the project's activity shows, if one runs. Its `finished` is the activity's own: only the Mac counts
    /// runs finishing while the app is closed.
    func shown(projectID: String) -> ProjectActivities.State?
    func start(projectID: String, projectName: String, state: ProjectActivities.State) async throws
    func end(projectID: String) async
    func endAll() async
    func reconcile(followed: [(id: String, name: String)], state: (String) -> ProjectActivities.State?) async -> [String: ProjectActivityRefusal]
}

/// ActivityKit itself.
///
/// It asks iOS for no push token yet (`throughRelay: false`): a token is only of use once it can be handed to the relay
/// (`activityToken` on the relay's socket, which RemoteKit's relay client does not send yet, #689) and the Mac told which
/// project the activity follows (a device request the engine does not have yet), and an unsigned build gets none (#682).
/// Until then the app keeps the activity's numbers while it is open, and the Lock Screen shows the last of them, dated.
struct SystemProjectActivities: ProjectActivityControl {
    static let asksForPushTokens = false

    var areAllowed: Bool { ProjectActivities.areAllowed }

    func shown(projectID: String) -> ProjectActivities.State? {
        ProjectActivities.running(projectID: projectID)?.content.state
    }

    func start(projectID: String, projectName: String, state: ProjectActivities.State) async throws {
        try await ProjectActivities.start(projectID: projectID, projectName: projectName, state: state, throughRelay: Self.asksForPushTokens)
    }

    func end(projectID: String) async {
        await ProjectActivities.end(projectID: projectID)
    }

    func endAll() async {
        await ProjectActivities.endAll()
    }

    func reconcile(followed: [(id: String, name: String)], state: (String) -> ProjectActivities.State?) async -> [String: ProjectActivityRefusal] {
        await ProjectActivities.reconcile(followed: followed, state: state, throughRelay: Self.asksForPushTokens)
    }
}

/// The projects whose Live Activity the person turned on (docs/iphone-app.md, "The Live Activity"), kept on the phone,
/// and the calls each change makes: the project's switch in its settings turns one on (`turnOn`) or off (`turnOff`); the
/// app's return to the foreground, and the Mac's numbers changing while it is in front, bring the activities in line
/// (`reconcile`); the end of the pairing ends them all (`endAll`).
///
/// The list is project ids alone, in a file of the app's own container, protected and out of backups, removed with the
/// pairing. The Mac is not told of it yet (a device request the engine does not have, #689).
@MainActor
@Observable
final class ProjectActivityFollowing {
    /// The followed projects' ids.
    private(set) var followed: Set<String> = []
    /// Why a project's activity was not started, for its switch to show.
    private(set) var problems: [String: String] = [:]
    /// Whether iOS allows pi²'s Live Activities (Settings › pi² › Live Activities): the switches are unavailable while not.
    private(set) var allowed: Bool
    /// The projects whose switch is being turned, so that it is not turned again meanwhile.
    private(set) var turning: Set<String> = []

    @ObservationIgnored private let session: AppSession
    @ObservationIgnored private let control: any ProjectActivityControl
    @ObservationIgnored private let file: URL?
    /// When the client last heard from the Mac, for the numbers' `at`: nil while there is nothing of the Mac to count.
    @ObservationIgnored private let heardAt: @MainActor () -> Date?
    @ObservationIgnored private var reconciling = false
    @ObservationIgnored private var reconcileAgain = false
    @ObservationIgnored private let log = Logger(subsystem: "dev.pi2.ios", category: "live-activity")

    /// Where the list is kept in the app's container.
    static var standardFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "LiveActivities/followed.json", directoryHint: .notDirectory)
    }

    init(session: AppSession, control: any ProjectActivityControl = SystemProjectActivities(), file: URL? = ProjectActivityFollowing.standardFile, heardAt: @escaping @MainActor () -> Date?) {
        self.session = session
        self.control = control
        self.file = file
        self.heardAt = heardAt
        allowed = control.areAllowed
        if let file, let data = try? Data(contentsOf: file), let ids = try? JSONDecoder().decode([String].self, from: data) {
            followed = Set(ids)
        }
        #if DEBUG
        if ProjectActivityFollowingDebug.offInIOS { allowed = false }
        #endif
    }

    func isOn(_ projectID: String) -> Bool { followed.contains(projectID) }

    /// Reads again whether iOS allows Live Activities: as the app comes to the foreground, since the person may have
    /// changed it in iOS's Settings meanwhile.
    func refreshAllowed() {
        allowed = control.areAllowed
        #if DEBUG
        if ProjectActivityFollowingDebug.offInIOS { allowed = false }
        #endif
    }

    /// The project's numbers as the client holds them, the Mac's way; nil while there is nothing of the Mac to count.
    func numbers(of projectID: String, finished: Int) -> ProjectActivities.State? {
        guard session.engine.hasLoadedLibrary, let at = heardAt() else { return nil }
        let e = session.engine
        return .counted(projectID: projectID, activity: e.activity, needs: e.needs, finished: finished, at: at)
    }

    /// The person turned the project's Live Activity on, in the foreground: it starts with the project's numbers now. On a
    /// refusal the switch shows why and stays off.
    func turnOn(_ project: ProjectRow) async {
        guard !turning.contains(project.id) else { return }
        turning.insert(project.id)
        defer { turning.remove(project.id) }
        problems[project.id] = nil
        refreshAllowed()
        guard allowed else {
            problems[project.id] = ProjectActivityRefusal.notAllowed.words
            return
        }
        guard let state = numbers(of: project.id, finished: 0) else {
            problems[project.id] = "Your Mac's numbers for this project have not come yet. Try again once they have."
            return
        }
        do {
            try await control.start(projectID: project.id, projectName: project.name, state: state)
            followed.insert(project.id)
            save()
        } catch {
            problems[project.id] = ProjectActivityRefusal(error).words
        }
    }

    /// The person turned it off: the activity goes at once.
    func turnOff(_ projectID: String) async {
        guard !turning.contains(projectID) else { return }
        turning.insert(projectID)
        defer { turning.remove(projectID) }
        problems[projectID] = nil
        followed.remove(projectID)
        save()
        await control.end(projectID: projectID)
    }

    /// Brings the activities in line with what is followed and the Mac's numbers: one started again for a busy project
    /// (iOS ends any after eight hours), the idle ones ended, the rest updated, any not followed ended. A project the Mac
    /// no longer has is no longer followed. Calls while one runs are run once more after it.
    func reconcile() async {
        guard !reconciling else {
            reconcileAgain = true
            return
        }
        reconciling = true
        defer { reconciling = false }
        repeat {
            reconcileAgain = false
            guard session.engine.hasLoadedLibrary, heardAt() != nil else { return }
            let projects = session.engine.projects.filter { $0.archivedAt == nil && $0.deletedAt == nil }
            let known = Set(projects.map(\.id))
            if !followed.isSubset(of: known) {
                followed.formIntersection(known)
                save()
            }
            let list = projects.filter { followed.contains($0.id) }.map { (id: $0.id, name: $0.name) }
            let refused = await control.reconcile(followed: list) { [self] id in latest(of: id) }
            for (id, refusal) in refused { problems[id] = refusal.words }
        } while reconcileAgain
    }

    /// The project's numbers for its running activity: the ones it shows while nothing but the time changed, so that the
    /// Mac's many events while an agent works do not each update it.
    private func latest(of projectID: String) -> ProjectActivities.State? {
        let shown = control.shown(projectID: projectID)
        guard let now = numbers(of: projectID, finished: shown?.finished ?? 0) else { return nil }
        if let shown, shown.working == now.working, shown.needs == now.needs { return shown }
        return now
    }

    /// Ends every activity and forgets what was followed: when the pairing ends or the store is wiped (3.6).
    func endAll() async {
        followed = []
        problems = [:]
        if let file { try? FileManager.default.removeItem(at: file) }
        await control.endAll()
    }

    private func save() {
        guard let file else { return }
        do {
            let folder = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
            try JSONEncoder().encode(followed.sorted()).write(to: file, options: [.atomic, .completeFileProtection])
            var url = folder
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } catch {
            log.error("The followed projects could not be kept: \(error.localizedDescription, privacy: .public)")
        }
    }
}

#if DEBUG
/// `PI2_LIVE_ACTIVITY_SWITCH=off-in-ios`, for a picture of a project's switch as while iOS has Live Activities off.
/// (`PI2_SETTINGS_PRESS=live-activity` turns the switch on as a tap would.)
enum ProjectActivityFollowingDebug {
    static var offInIOS: Bool { ProcessInfo.processInfo.environment["PI2_LIVE_ACTIVITY_SWITCH"] == "off-in-ios" }
}
#endif
