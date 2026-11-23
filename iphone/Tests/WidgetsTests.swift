import EngineKit
import Foundation
import PiModels
import SwiftUI
import Testing
import UIKit
import WidgetKit
@testable import pi2

/// The widgets (#699, `iphone/Widgets/`): the snapshot the app makes of what its client holds, the file it is written
/// to and read from, the links a tap opens, where their content is private, and every widget drawn in every family from
/// a stand-in store: the demo's recording, the session the demo mode shows, with plan windows added below that no
/// recording holds. The pictures are drawn with `ImageRenderer`, the same views the extension draws, since the widget
/// gallery opens only with a tap; to keep them, make `app/build/shots/699/` in the checkout and run this suite.
@MainActor
struct WidgetsTests {
    private func eventually(_ seconds: Double = 30, _ condition: () -> Bool) async throws -> Bool {
        let end = Date(timeIntervalSinceNow: seconds)
        while !condition() {
            if Date() > end { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// A session on the demo's recording, once its needs, runs and usage are in.
    private func demo() async throws -> AppSession {
        let transport = try #require(DemoTransport.recorded(), "the demo's recording is in the app's bundle")
        transport.world.pace = 0.02
        let session = AppSession()
        session.start(transport, as: .demo)
        #expect(try await eventually {
            !session.engine.needs.isEmpty && !session.engine.activity.isEmpty && session.engine.usage != nil
                && !session.engine.allAgents.isEmpty && !session.engine.projects.isEmpty
        })
        return session
    }

    /// A `limits` event as engine/src/limits.ts sends it. **Stand-in values for the tests**: no recording holds a
    /// subscription's windows.
    private static let standInLimits: JSONValue = try! JSONDecoder().decode(JSONValue.self, from: Data("""
    {"providers":[
      {"id":"anthropic","name":"Stand-in","plan":"Max","note":null,"reports":"usage","fetchedAt":1,"source":"usage",
       "error":null,"errorAt":null,"refreshing":false,"windows":[
        {"id":"five_hour","label":"5-hour window","usedPercent":62.4,"resetsAt":\(Int(Date().addingTimeInterval(7_200).timeIntervalSince1970 * 1000))},
        {"id":"seven_day","label":"This week","usedPercent":84,"resetsAt":null},
        {"id":"seven_day_opus","label":"This week (Opus)","usedPercent":130,"resetsAt":null}]},
      {"id":"key","name":"A key","plan":null,"note":null,"reports":"none","fetchedAt":null,"source":null,
       "error":null,"errorAt":null,"refreshing":false,"windows":[]}],
     "notices":[]}
    """.utf8))

    private func snapshot(_ engine: EngineSession<MessageField>, limits: JSONValue? = nil, heardAt: Date = Date()) -> WidgetsSnapshot {
        WidgetsSnapshot(
            needs: engine.needs, activity: engine.activity, projects: engine.projects, agents: engine.allAgents,
            usage: engine.usage, limits: limits ?? engine.extras["limits"], heardAt: heardAt, macName: "Demo Mac"
        )
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "widgets-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - The snapshot

    @Test func theSnapshotHoldsCountsAndNamesFromTheClient() async throws {
        let session = try await demo()
        let engine = session.engine
        let made = snapshot(engine)

        #expect(made.needs.count == engine.needs.count)
        #expect(made.needs.newest.count == min(engine.needs.count, WidgetsSnapshot.named))
        #expect(made.needs.newest.map(\.createdAt) == made.needs.newest.map(\.createdAt).sorted(by: >))
        let newest = try #require(engine.needs.max { $0.createdAt < $1.createdAt })
        #expect(made.needs.newest.first?.id == newest.id)
        #expect(made.needs.newest.first?.projectName == engine.projects.first { $0.id == newest.projectId }?.name)
        for need in made.needs.newest {
            // Who asks and what kind, never what the card says.
            let item = try #require(engine.needs.first { $0.id == need.id })
            #expect(need.title == WidgetsSnapshot.title(of: item))
            if let question = item.question { #expect(!need.title.contains(question)) }
        }

        // Each agent at work once per project, named, with its project; no chat.
        let runs = engine.activity.filter { $0.chat != true }
        #expect(!made.working.isEmpty)
        #expect(made.working.reduce(0) { $0 + $1.runs } <= runs.count)
        #expect(Set(made.working.map(\.id)).count == made.working.count)
        for worker in made.working {
            #expect(engine.allAgents.contains { $0.id == worker.agentID && $0.name == worker.agentName })
            #expect(worker.projectName != nil)
        }
        // Waiting for the person comes last, and does not count as at work.
        let waits = made.working.filter { $0.state == .waitsForYou }
        #expect(made.working.suffix(waits.count).allSatisfy { $0.state == .waitsForYou })
        #expect(made.workingCount == made.working.count - waits.count)

        let usage = try #require(engine.usage)
        #expect(made.spending == WidgetsSnapshot.Spending(
            todayCost: usage.today.cost, todayTokens: usage.today.tokens, dailyBudget: usage.budget.daily,
            overBudget: usage.overBudget, windows: []
        ))
    }

    @Test func nothingFromTheMacMakesNothingUp() {
        let made = WidgetsSnapshot(needs: [], activity: [], projects: [], agents: [], usage: nil, limits: nil, heardAt: Date(), macName: nil)
        #expect(made.needs == WidgetsSnapshot.Needs(count: 0, newest: []))
        #expect(made.working.isEmpty)
        #expect(made.spending == nil)
    }

    @Test func planWindowsAreReadFromTheLimitsEvent() {
        let windows = WidgetsSnapshot.windows(Self.standInLimits)
        #expect(windows.map(\.id) == ["anthropic.seven_day_opus", "anthropic.seven_day", "anthropic.five_hour"])
        #expect(windows.map(\.usedPercent) == [100, 84, 62.4])
        #expect(windows.allSatisfy { $0.provider == "Stand-in Max" })
        #expect(windows.last?.resetsAt != nil)
        #expect(WidgetsSnapshot.windows(nil).isEmpty)
        #expect(WidgetsSnapshot.windows(.string("not an event")).isEmpty)
    }

    // MARK: - The file

    @Test func theFileKeepsASnapshotAndReadsItBack() throws {
        let file = WidgetsFile(folder: try folder())
        let written = WidgetsSnapshot(
            heardAt: Date(timeIntervalSince1970: 1_795_392_000), macName: "Mac",
            needs: .init(count: 2, newest: [.init(id: "n2", title: "Forge needs approval", agentName: "Forge", agentColor: "orange", projectID: "p-1", projectName: "pi2", createdAt: Date(timeIntervalSince1970: 1_795_391_000))]),
            working: [.init(agentID: "atlas", agentName: "Atlas", agentColor: nil, projectID: "p-1", projectName: "pi2", conversationID: 17, since: Date(timeIntervalSince1970: 1_795_390_000), runs: 2, state: .working)],
            spending: .init(todayCost: 1.5, todayTokens: 1_000, dailyBudget: 20, overBudget: false, windows: [])
        )
        #expect(file.read() == nil)
        try file.write(written)
        #expect(file.read(now: written.heardAt.addingTimeInterval(60)) == written)

        let url = try #require(file.url)
        #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        // The simulator keeps no data protection, and says none; a phone says the class the file was written with.
        if let protection = try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey] as? FileProtectionType {
            #expect(protection == .completeUntilFirstUserAuthentication)
        }

        // Older than the store keeps the Mac's state: not drawn.
        #expect(file.read(now: written.heardAt.addingTimeInterval(WidgetsSnapshot.keptFor + 1)) == nil)
        // Another version, or what is not a snapshot: not drawn.
        var other = written
        other.version = WidgetsSnapshot.currentVersion + 1
        try file.write(other)
        #expect(file.read(now: written.heardAt) == nil)
        try Data("{".utf8).write(to: url)
        #expect(file.read(now: written.heardAt) == nil)

        file.remove()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        file.remove()
    }

    @Test func aBuildWithNoAppGroupWritesAndReadsNothing() throws {
        let none = WidgetsFile(folder: nil)
        try none.write(WidgetsSnapshot(needs: [], activity: [], projects: [], agents: [], usage: nil, limits: nil, heardAt: Date(), macName: nil))
        #expect(none.read() == nil)
        none.remove()
        // The simulator's unsigned build has no app group, so the standard file has no folder there (docs/iphone-app.md).
        if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetsFile.appGroup) == nil {
            #expect(WidgetsFile.standard.folder == nil)
        }
    }

    @Test func thePublisherWritesOnlyWhatChanged() async throws {
        let file = WidgetsFile(folder: try folder())
        var reloads = 0
        let publisher = WidgetsPublisher(file: file, reload: { reloads += 1 })
        // Whole seconds: the file keeps milliseconds.
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        var snapshot = WidgetsSnapshot(needs: [], activity: [], projects: [], agents: [], usage: nil, limits: nil, heardAt: now, macName: nil)

        publisher.update(snapshot)
        publisher.flush()
        #expect(reloads == 1)
        #expect(file.read() == snapshot)

        // Only the time moved on, a little: nothing written.
        snapshot.heardAt = now.addingTimeInterval(60)
        publisher.update(snapshot)
        publisher.flush()
        #expect(reloads == 1)
        // Far enough that "Updated" would be behind: written.
        snapshot.heardAt = now.addingTimeInterval(WidgetsPublisher.staleAfter + 1)
        publisher.update(snapshot)
        publisher.flush()
        #expect(reloads == 2)

        // A burst of changes is one write, after the delay.
        for count in 1...5 {
            snapshot.needs.count = count
            publisher.update(snapshot)
        }
        #expect(try await eventually(10) { reloads == 3 })
        #expect(file.read()?.needs.count == 5)

        publisher.clear()
        #expect(reloads == 4)
        #expect(file.read() == nil)
    }

    // MARK: - Links, privacy, the timeline

    @Test func linksNameRoutesAndNothingElse() throws {
        let links: [WidgetsLink] = [
            .needs(), .needs(project: "p-554f6bae-f4f0", need: "n12"), .needs(project: "p-1"),
            .conversation(139), .dashboard(), .dashboard(project: "p-1"), .usage,
        ]
        for link in links {
            #expect(WidgetsLink(link.url) == link, "\(link.url)")
            #expect(link.url.scheme == "pi2-widget")
        }
        #expect(WidgetsLink.needs(project: "p-1", need: "n2").url.absoluteString == "pi2-widget://needs?project=p-1&need=n2")
        #expect(WidgetsLink.conversation(139).url.absoluteString == "pi2-widget://conversation?id=139")
        for refused in [
            "pi2://needs", "https://needs", "pi2-widget://settings", "pi2-widget://conversation", "pi2-widget://conversation?id=x",
            "pi2-widget://conversation?id=-3", "pi2-widget://needs?project=", "pi2-widget://needs?project=a%20b",
            "pi2-widget://needs?folder=p-1", "pi2-widget://usage?id=1", "pi2-widget://needs/extra", "pi2-widget://needs?project=a&project=b",
        ] {
            #expect(WidgetsLink(try #require(URL(string: refused))) == nil, "\(refused)")
        }
    }

    @Test func contentIsPrivateOnTheLockScreenAndInStandBy() {
        for family in [WidgetFamily.accessoryCircular, .accessoryRectangular, .accessoryInline] {
            #expect(WidgetsPrivacy.isPrivate(family, showsBackground: true))
            #expect(WidgetsPrivacy.isPrivate(family, showsBackground: false))
        }
        for family in [WidgetFamily.systemSmall, .systemMedium, .systemLarge] {
            #expect(!WidgetsPrivacy.isPrivate(family, showsBackground: true), "the Home Screen")
        }
        #expect(WidgetsPrivacy.isPrivate(.systemSmall, showsBackground: false), "StandBy")
    }

    @Test func theTimelineEndsWhenTheSnapshotIsTooOld() {
        let heard = Date(timeIntervalSince1970: 1_795_392_000)
        let snapshot = WidgetsSnapshot(needs: [], activity: [], projects: [], agents: [], usage: nil, limits: nil, heardAt: heard, macName: nil)
        let timeline = WidgetsTimeline.timeline(snapshot, now: heard.addingTimeInterval(10))
        #expect(timeline.entries.map(\.snapshot) == [snapshot, nil])
        #expect(timeline.entries.last?.date == heard.addingTimeInterval(WidgetsSnapshot.keptFor))
        #expect(WidgetsTimeline.timeline(nil, now: heard).entries.map(\.snapshot) == [nil])
    }

    // MARK: - Every widget in every family

    @Test func everyWidgetDrawsInEveryFamily() async throws {
        let session = try await demo()
        let full = snapshot(session.engine, limits: Self.standInLimits)
        let empty = WidgetsSnapshot(
            heardAt: Date(), macName: nil, needs: .init(count: 0, newest: []), working: [],
            spending: .init(todayCost: 0, todayTokens: 0, dailyBudget: nil, overBudget: false, windows: [])
        )
        var over = full
        over.spending?.dailyBudget = 0.5
        over.spending?.overBudget = true

        let shots = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../app/build/shots/699")
        let keep = FileManager.default.fileExists(atPath: shots.path)

        let states: [(name: String, snapshot: WidgetsSnapshot?)] = [("", full), ("-empty", empty), ("-nothing-yet", nil)]
        for kind in WidgetsKind.allCases {
            for state in states {
                for look in WidgetsBoard.Look.allCases where state.name.isEmpty || look == .light {
                    let board = WidgetsBoard(kind: kind, snapshot: state.snapshot, look: look)
                    let image = try #require(Self.render(board, look: look), "\(kind) \(look) drew")
                    #expect(image.size.width > 300 && image.size.height > 300)
                    if keep {
                        try #require(image.pngData()).write(to: shots.appending(path: "\(kind.rawValue)\(state.name)-\(look.rawValue).png"))
                    }
                }
            }
        }
        let overBoard = WidgetsBoard(kind: .spending, snapshot: over, look: .light)
        let image = try #require(Self.render(overBoard, look: .light))
        if keep { try #require(image.pngData()).write(to: shots.appending(path: "spending-over-budget-light.png")) }
    }

    private static func render(_ board: WidgetsBoard, look: WidgetsBoard.Look) -> UIImage? {
        let renderer = ImageRenderer(content: board
            .environment(\.colorScheme, look == .dark ? .dark : .light)
            .environment(\.dynamicTypeSize, look == .largest ? .accessibility5 : .large))
        renderer.scale = 2
        return renderer.uiImage
    }
}

/// Every family of one widget on one picture, at an iPhone's sizes in points: the Home Screen's three, StandBy's, and
/// the Lock Screen's three, each of the last two also as a locked phone draws them, with what is private redacted. The
/// Lock Screen is drawn as the app draws its views, in colour, not in iOS's own vibrant mode.
private struct WidgetsBoard: View {
    enum Look: String, CaseIterable { case light, dark, largest }

    let kind: WidgetsKind
    let snapshot: WidgetsSnapshot?
    let look: Look

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(kind.name): \(look.rawValue)").font(.headline)
            caption("Home Screen")
            HStack(alignment: .top, spacing: 16) {
                home(.systemSmall, width: 170, height: 170)
                home(.systemMedium, width: 364, height: 170)
            }
            home(.systemLarge, width: 364, height: 382)
            caption("StandBy (the small widget without its background), unlocked and locked")
            HStack(spacing: 16) {
                standBy(locked: false)
                standBy(locked: true)
            }
            caption("Lock Screen, unlocked and locked")
            HStack(alignment: .top, spacing: 16) {
                lock(locked: false)
                lock(locked: true)
            }
        }
        .padding(20)
        .frame(width: 790, alignment: .topLeading)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    private func widget(_ family: WidgetFamily) -> some View {
        WidgetsView(kind: kind, snapshot: snapshot, family: family)
    }

    private func home(_ family: WidgetFamily, width: CGFloat, height: CGFloat) -> some View {
        widget(family)
            .padding(16)
            .frame(width: width, height: height)
            .background(WidgetsColor.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func standBy(locked: Bool) -> some View {
        widget(.systemSmall)
            .environment(\.widgetsArePrivate, true)
            .redacted(reason: locked ? .privacy : [])
            .padding(16)
            .frame(width: 170, height: 170)
            .background(.black, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .environment(\.colorScheme, .dark)
    }

    private func lock(locked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            widget(.accessoryInline).font(.subheadline).lineLimit(1).frame(width: 240, height: 22, alignment: .leading)
            HStack(spacing: 10) {
                widget(.accessoryCircular)
                    .frame(width: 72, height: 72)
                    .background(Circle().fill(.white.opacity(0.18)))
                widget(.accessoryRectangular)
                    .frame(width: 160, height: 72)
            }
        }
        .environment(\.widgetsArePrivate, true)
        .redacted(reason: locked ? .privacy : [])
        .foregroundStyle(.white)
        .padding(12)
        .frame(width: 357, alignment: .leading)
        .background(
            LinearGradient(colors: [Color(red: 0.16, green: 0.2, blue: 0.42), Color(red: 0.36, green: 0.2, blue: 0.4)], startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .environment(\.colorScheme, .dark)
    }
}
