import ComposeKit
import MenuKit
import SwiftUI
import WindowKit

// The Dashboard (#481, #618; docs/design/projects.md "The Dashboard", docs/projects.md 10.1 and 10.3): the projects the
// person ticks, a column each — the project's vitals in one line, what needs them, answered in place, who is working now,
// and a window onto the orchestrator's conversation over a field that messages it, with a button to the project's own
// hub. Every part that changes while agents work is drawn by the views the board's tabs already use: the Now tab's cards
// and working rows (#472) and the folded conversation's strip (#471), so nothing here copies what a project's hub already
// shows. More columns than fit scroll sideways; the window never resizes for them, and pi2-window-check checks that.

/// The projects ticked on the Dashboard are the app's own, by id (`dashboard.projects`, docs/projects.md 10.1): they are
/// kept in the preferences, and the engine has no use for them. Nil when the person has never chosen, meaning every
/// project that is not archived.
enum DashboardWatch {
    static let key = "dashboard.projects"

    /// The ticked projects, or nil when no choice has been made.
    static func saved() -> Set<String>? {
        UserDefaults.standard.stringArray(forKey: key).map(Set.init)
    }

    /// Saves the choice. An empty set is a choice too: nothing watched.
    static func save(_ ids: Set<String>) {
        UserDefaults.standard.set(Array(ids), forKey: key)
    }
}

/// The Dashboard: a small control that ticks the projects to watch, then a column per project, in the sidebar's order.
struct DashboardView: View {
    let model: AppModel
    /// The projects ticked, once the person has chosen; nil until then, which watches every project that is not
    /// archived. Read once as the view is made, and written by the Projects… menu.
    @State private var chosen: Set<String>?
    /// The columns on screen: only those draw their window onto the orchestrator and ask the engine for it (#618).
    @State private var onScreen: Set<String> = []

    private var engine: EngineClient { model.engine }
    /// The projects the sidebar lists, in its order: not archived, not deleted.
    private var listed: [ProjectRow] { engine.projects.filter { $0.archivedAt == nil && $0.deletedAt == nil } }
    /// The projects to watch: those ticked, or every listed one until a choice is made. One archived or deleted since
    /// drops out by itself, and comes back if it is restored while still ticked.
    private var watched: [ProjectRow] {
        let ticked = chosen ?? Set(listed.map(\.id))
        return listed.filter { ticked.contains($0.id) }
    }

    init(model: AppModel) {
        self.model = model
        _chosen = State(initialValue: DashboardWatch.saved())
    }

    var body: some View {
        VStack(spacing: 0) {
            bar
            if watched.isEmpty {
                empty
            } else {
                GeometryReader { space in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(watched) { project in
                                DashboardColumn(model: model, project: project, visible: onScreen.contains(project.id))
                                    .frame(width: Self.columnWidth(watched.count, in: space.size.width))
                                    .frame(minHeight: 0, maxHeight: .infinity)
                                    .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
                                    .onScrollVisibilityChange(threshold: 0.05) { shown in
                                        if shown { onScreen.insert(project.id) } else { onScreen.remove(project.id) }
                                    }
                            }
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                }
            }
        }
        .background(Theme.window)
        .navigationTitle("Dashboard")
        #if PI2_DEVELOPMENT
        // What a test copy's `show` waits for (#469): the Dashboard has drawn these projects' columns.
        .onChange(of: watched.map(\.id), initial: true) { _, ids in DashboardDrawn.current = ids }
        .onDisappear { DashboardDrawn.current = nil }
        #endif
        // The windows onto the orchestrators register what they show while they are on screen; nothing is left behind.
        .onDisappear { model.dashboardConversations = [] }
    }

    /// One column's width: the columns share the window's width between them, so three or four fill it as the design
    /// draws them (docs/design/projects-drafts.html, screen 5), and never narrower than 300 points, so that more than
    /// fit scroll sideways rather than squeeze. The window is never asked for more room either way.
    static func columnWidth(_ count: Int, in width: CGFloat) -> CGFloat {
        guard count > 0, width > 0 else { return minimumColumnWidth }
        return max(minimumColumnWidth, (width / CGFloat(count)).rounded(.down))
    }

    /// The narrowest a column gets before the row scrolls instead.
    static let minimumColumnWidth: CGFloat = 290

    // MARK: The projects to watch

    private var bar: some View {
        HStack(spacing: 10) {
            Menu {
                MenuChoices(listed.map { MenuChoice(id: $0.id, title: $0.name, ticked: watching($0.id)) }) { tick($0.id) }
                if listed.isEmpty {
                    Button("No projects yet. Make one from a folder with +.") {}.disabled(true)
                }
            } label: {
                Label("Projects…", systemImage: "square.grid.2x2")
            }
            .menuStyle(.button)
            .controlSize(.small)
            .fixedSize()
            .help("Tick the projects to watch here; their columns show what needs you, who is working and the orchestrator’s last words")
            if !watched.isEmpty {
                Text(watched.count == 1 ? "Watching 1 project" : "Watching \(watched.count) projects")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.tx3)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func watching(_ id: String) -> Bool {
        (chosen ?? Set(listed.map(\.id))).contains(id)
    }

    /// Ticks or unticks one project, and remembers the whole choice.
    private func tick(_ id: String) {
        var set = chosen ?? Set(listed.map(\.id))
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        chosen = set
        DashboardWatch.save(set)
    }

    /// What shows when there is no project to watch.
    private var empty: some View {
        ContentUnavailableView {
            Label(listed.isEmpty ? "No projects to watch" : "Nothing watched", systemImage: "square.grid.2x2")
        } description: {
            Text(listed.isEmpty
                 ? "Make a project from a folder with + in the sidebar, and it is watched here from the start."
                 : "Tick the projects to watch with Projects… above.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One project's column: its name and badge with a button to its hub, its vitals in a line, what needs the person
/// answered in place, who is working now, and at the foot a window onto the orchestrator's conversation over a field
/// that messages it. The needs scroll within a space of their own, in the manner of the requests above a conversation's
/// field (#489), so they never push the working rows or the orchestrator's window out of the column.
private struct DashboardColumn: View {
    let model: AppModel
    let project: ProjectRow
    /// Whether the column is on screen, for the window onto the orchestrator.
    let visible: Bool

    /// The engine's answer when an answer fails, by the need's id: shown under that need's controls.
    @State private var problems: [String: String] = [:]
    /// The answer being typed into a question's or a decision's field, by the need's id.
    @State private var words: [String: String] = [:]
    /// The needs whose answer is on its way: a second click while it goes does nothing (#481).
    @State private var answering: Set<String> = []
    /// The column's height, for the space the needs scroll within.
    @State private var height: CGFloat = 0
    /// The height of the window onto the orchestrator, with its header and field.
    @State private var paneHeight: CGFloat = 0

    private var engine: EngineClient { model.engine }
    private var needs: [NeedItem] { engine.needs.filter { $0.projectId == project.id } }
    private var runs: [ActivityRun] { engine.activity.filter { $0.projectId == project.id && $0.chat != true } }
    private var waking: Bool { project.settings?.wakeOnReports ?? false }
    private var live: ProjectLive { engine.projectStore.live(project.id) }

    var body: some View {
        VStack(spacing: 0) {
            header
            ProjectVitals(model: model, project: project)
            needsSection
            Divider().overlay(Theme.line)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    workingSection
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 0)
            // The window takes at most a third or so of what the column has beside its header, vitals and field, so that
            // at the window's smallest size a card and a working row still show above it.
            OrchestratorPane(model: model, project: project, visible: visible, tallest: max(DashboardPaneLayout.minimumHeight, (height - 170) * 0.35))
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { paneHeight = $0 }
        }
        .background(Theme.window)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
    }

    // MARK: The header

    /// The project's name with its badge, and the button to its hub.
    private var header: some View {
        HStack(spacing: 8) {
            ProjectMark(name: project.name, color: engine.agent(project.orchestratorId)?.color, size: 18)
            Text(project.name)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.tx)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 6)
            if live.needs > 0 {
                Tag("\(live.needs)", .warn).fixedSize()
                    .help(live.needs == 1 ? "1 thing waits for you" : "\(live.needs) things wait for you")
                    .accessibilityLabel("\(live.needs) waiting on you")
            } else if live.working > 0 {
                Tag("\(live.working) working", .acc).fixedSize()
                    .accessibilityLabel("\(live.working) working")
            } else {
                Tag("idle").fixedSize()
            }
            Button("Open") { model.showProject(project.id) }
                .buttonStyle(.piGhost)
                .fixedSize()
                .help("Open the project’s own hub, beside the Dashboard")
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    // MARK: Needs you

    private var needsSection: some View {
        VStack(spacing: 0) {
            ProjectSectionHeader(title: "Needs you", count: needs.count)
            if needs.isEmpty {
                QuietLine(text: "Nothing needs you right now.")
            } else {
                // However many there are, they scroll within a space of their own and never push what is below out of
                // the column (#489's stack): at most 60% of what is left after the column's header, its vitals and the
                // orchestrator's window.
                ConversationRequests(needs, availableHeight: max(120, height - 62 - paneHeight)) { need in
                    NeedCard(
                        model: model, need: need, problem: problems[need.id],
                        words: Binding(get: { words[need.id] ?? "" }, set: { words[need.id] = $0 }),
                        answer: answer, compact: true
                    )
                }
            }
        }
    }

    // MARK: Working

    private var workingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Working").sectionLabel()
            if runs.isEmpty {
                QuietLine(text: "Nobody is working right now.")
            } else {
                ForEach(runs) { run in
                    WorkingRow(engine: engine, run: run, waking: waking, compact: true) {
                        model.openAgent(run.conversationId, in: project.id)
                    }
                }
            }
        }
    }

    // MARK: Answering

    /// Sends one answer to a need through the one request every kind answers by (`needs.answer`, docs/projects.md,
    /// 4.2), and keeps the engine's refusal on the card it was given from.
    private func answer(_ need: NeedItem, _ reply: [String: Any]) {
        guard !answering.contains(need.id) else { return }
        answering.insert(need.id)
        Task {
            do {
                try await engine.call("needs.answer", ["id": need.id, "answer": reply])
                problems[need.id] = nil
                words[need.id] = nil
            } catch {
                problems[need.id] = error.localizedDescription
            }
            answering.remove(need.id)
        }
    }
}

// MARK: - The vitals

/// A project's vitals, in one quiet line at the top of its column (#618): what needs the person, who is working (and how
/// many wait for a provider's limit, until when), what finished today and how much of it the orchestrator has not read,
/// and what the project spent today, against its limit when it has one. Each part opens the hub where it is shown: the
/// Now tab, or the Settings tab for the spending. In a narrow column the words give way to shorter ones.
struct ProjectVitals: View {
    let model: AppModel
    let project: ProjectRow

    private var engine: EngineClient { model.engine }

    /// One part of the line: its words, shorter words for a narrow column, its colour, and the tab it opens.
    struct Part: Identifiable {
        let id: String
        let long: String
        let short: String
        var tone: Color = Theme.tx2
        let tab: HubTab
        let help: String
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let parts = parts(now: context.date)
            HStack(spacing: 0) {
                if parts.isEmpty {
                    Text("Nothing waits, nobody is working, nothing finished today.")
                        .foregroundStyle(Theme.tx3)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    ViewThatFits(in: .horizontal) {
                        line(parts, short: false)
                        line(parts, short: true)
                        line(parts, short: true).lineLimit(1).truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background(Theme.panel)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        }
    }

    private func line(_ parts: [Part], short: Bool) -> some View {
        HStack(spacing: 5) {
            ForEach(Array(parts.enumerated()), id: \.element.id) { index, part in
                if index > 0 { Text("·").foregroundStyle(Theme.tx3) }
                Button(short ? part.short : part.long) { model.showProject(project.id, tab: part.tab) }
                    .buttonStyle(.plain)
                    .foregroundStyle(part.tone)
                    .fixedSize()
                    .help(part.help)
            }
        }
    }

    /// The parts with something to say, in the order the line reads.
    func parts(now: Date) -> [Part] {
        var parts: [Part] = []
        let needs = engine.needs.filter { $0.projectId == project.id }.count
        if needs > 0 {
            parts.append(Part(id: "needs", long: "\(needs) need\(needs == 1 ? "s" : "") you", short: "\(needs) need\(needs == 1 ? "s" : "") you", tone: Theme.warn, tab: .now,
                              help: needs == 1 ? "1 thing waits for you. Open the Now tab." : "\(needs) things wait for you. Open the Now tab."))
        }
        let runs = engine.activity.filter { $0.projectId == project.id && $0.chat != true }
        if !runs.isEmpty {
            let limited = runs.compactMap(\.limit)
            var long = "\(runs.count) working"
            var short = long
            var help = runs.count == 1 ? "1 agent is working." : "\(runs.count) agents are working."
            if let until = limited.map(\.until).max() {
                let time = LimitsFormat.date(until).formatted(date: .omitted, time: .shortened)
                long += ", \(limited.count) on a limit until \(time)"
                short += " (\(limited.count) until \(time))"
                help += limited.count == 1 ? " 1 waits for a provider's limit, until \(time)." : " \(limited.count) wait for a provider's limit, the last until \(time)."
            }
            parts.append(Part(id: "working", long: long, short: short, tone: limited.isEmpty ? Theme.tx2 : Theme.warn, tab: .now, help: help + " Open the Now tab."))
        }
        let reports = ProjectReports(engine.extras["reports"]?["projects"]?[project.id]).items
        if !reports.isEmpty {
            let unread = reports.filter { $0.deliveredBy == nil }.count
            parts.append(Part(id: "finished", long: "\(reports.count) finished today\(unread > 0 ? ", \(unread) unread" : "")",
                              short: "\(reports.count) done\(unread > 0 ? " (\(unread) unread)" : "")", tab: .now,
                              help: "\(reports.count) finished today\(unread > 0 ? "; the orchestrator has not read \(unread) of their reports yet" : ""). Open the Now tab."))
        }
        let spent = engine.usage?.projects?.first { $0.id == project.id }?.today.cost ?? 0
        let limit = project.settings?.limits.dailySpend
        if spent > 0 || limit != nil {
            let over = limit.map { spent >= $0 } ?? false
            let words = limit.map { "\(Formats.cost(spent)) of \(Formats.cost($0))" } ?? Formats.cost(spent)
            parts.append(Part(id: "spent", long: "\(words) today", short: words, tone: over ? Theme.bad : Theme.tx2, tab: .settings,
                              help: "Spent today in the project's conversations, sub-chats included\(limit == nil ? "" : ", against its daily limit"). Open the Settings tab."))
        }
        return parts
    }
}

#if PI2_DEVELOPMENT
/// What the Dashboard last drew, for a test copy's `show`, which answers once the Dashboard has drawn it.
@MainActor
enum DashboardDrawn {
    /// The projects whose columns the Dashboard drew, in order; nil when it is not on screen.
    static var current: [String]?
}
#endif
