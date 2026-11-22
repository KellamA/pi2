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

/// How the person arranged the Dashboard's columns, kept in the app's preferences (docs/projects.md, 10.1): their order,
/// by project id (`dashboard.order`; a project not in it comes after, in the sidebar's order), and which are folded to a
/// narrow strip (`dashboard.<id>.columnFolded`, #618).
enum DashboardArrangement {
    static let orderKey = "dashboard.order"

    static func order() -> [String] { UserDefaults.standard.stringArray(forKey: orderKey) ?? [] }

    static func saveOrder(_ ids: [String]) { UserDefaults.standard.set(ids, forKey: orderKey) }

    /// `projects` in the person's order.
    static func arranged(_ projects: [ProjectRow], order: [String]) -> [ProjectRow] {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return projects.enumerated()
            .sorted { (rank[$0.element.id] ?? order.count + $0.offset, $0.offset) < (rank[$1.element.id] ?? order.count + $1.offset, $1.offset) }
            .map(\.element)
    }

    /// The order with `id` moved to just before `before`, or to the end when `before` is nil.
    static func moving(_ id: String, before: String?, in shown: [String]) -> [String] {
        var ids = shown.filter { $0 != id }
        if let before, let index = ids.firstIndex(of: before) { ids.insert(id, at: index) } else { ids.append(id) }
        return ids
    }

    static func folded(_ id: String) -> Bool { UserDefaults.standard.bool(forKey: "dashboard.\(id).columnFolded") }

    static func setFolded(_ folded: Bool, for id: String) {
        UserDefaults.standard.set(folded, forKey: "dashboard.\(id).columnFolded")
    }
}

/// What the keyboard asks of the Dashboard, from the View menu (`DashboardCommands`): a column's field, or the first
/// thing that needs the person. Counters, so that asking twice for the same thing asks again.
@MainActor
@Observable
final class DashboardKeys {
    /// The column asked for, from 1, and how many times anything was asked.
    private(set) var column = 0
    private(set) var columnAsks = 0
    private(set) var firstNeedAsks = 0

    func messageColumn(_ number: Int) {
        column = number
        columnAsks += 1
    }

    func showFirstNeed() { firstNeedAsks += 1 }
}

/// The View menu's commands for the Dashboard (#618): ⌥⌘1 to ⌥⌘9 put the keyboard in that column's field, and ⌥⌘0 brings
/// the first thing that needs the person into view. ⌘1 and ⌘2 are the window's Agents and Chat already, so the keys
/// have ⌥ as well, as the hub's do. A view of its own, so that what it reads draws this menu again and not every scene.
struct DashboardCommands: View {
    let model: AppModel

    var body: some View {
        if model.engine.projectsPreview {
            let shown = model.selection == .dashboard
            Menu("Dashboard") {
                Button("Show What Needs You First") { model.dashboardKeys.showFirstNeed() }
                    .keyboardShortcut("0", modifiers: [.command, .option])
                    .disabled(!shown)
                // The line's Stop All from the keyboard (#645). Not disabled by what runs, which changes many times a
                // second while agents work and would draw the menu again each time; the confirmation says when nothing
                // does.
                Button("Stop All Runs…") { model.stoppingAll = StopAllRequest(projects: DashboardView.watchedIDs(model.engine)) }
                    .keyboardShortcut(".", modifiers: [.command, .option])
                    .disabled(!shown)
                Divider()
                ForEach(1...9, id: \.self) { number in
                    Button("Message the Orchestrator in Column \(number)") { model.dashboardKeys.messageColumn(number) }
                        .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: [.command, .option])
                        .disabled(!shown)
                }
            }
        }
    }
}

/// The Dashboard: a small control that ticks the projects to watch, with a line across them all, then a column per
/// project, in the person's own order.
struct DashboardView: View {
    let model: AppModel
    /// The projects ticked, once the person has chosen; nil until then, which watches every project that is not
    /// archived. Read once as the view is made, and written by the Projects… menu.
    @State private var chosen: Set<String>?
    /// The columns on screen: only those draw their window onto the orchestrator and ask the engine for it (#618).
    @State private var onScreen: Set<String> = []
    /// The person's order of the columns, and the columns folded to a strip (#618).
    @State private var order: [String] = DashboardArrangement.order()
    @State private var foldedColumns: Set<String> = []
    /// Which column's field the keyboard was asked for, and how many times, for the column to take it.
    @State private var focus: (project: String, asks: Int) = ("", 0)
    /// The Dashboard's height: below `shortHeight` the limit notices keep to one line's room, so that the columns keep
    /// theirs (#645).
    @State private var height: CGFloat = 0
    static let shortHeight: CGFloat = 640

    private var engine: EngineClient { model.engine }
    /// The projects the sidebar lists, in its order: not archived, not deleted.
    private var listed: [ProjectRow] { engine.projects.filter { $0.archivedAt == nil && $0.deletedAt == nil } }
    /// The projects to watch: those ticked, or every listed one until a choice is made. One archived or deleted since
    /// drops out by itself, and comes back if it is restored while still ticked.
    private var watched: [ProjectRow] {
        let ticked = chosen ?? Set(listed.map(\.id))
        return DashboardArrangement.arranged(listed.filter { ticked.contains($0.id) }, order: order)
    }

    /// The projects the Dashboard watches, as the menu's Stop All counts them: those ticked, or every listed one.
    @MainActor
    static func watchedIDs(_ engine: EngineClient) -> Set<String> {
        let listed = Set(engine.projects.filter { $0.archivedAt == nil && $0.deletedAt == nil }.map(\.id))
        return DashboardWatch.saved().map { $0.intersection(listed) } ?? listed
    }

    init(model: AppModel) {
        self.model = model
        _chosen = State(initialValue: DashboardWatch.saved())
        _foldedColumns = State(initialValue: Set(model.engine.projects.map(\.id).filter(DashboardArrangement.folded)))
    }

    var body: some View {
        VStack(spacing: 0) {
            // The engine's notice that it restarted, over the whole Dashboard (#645).
            RecoveryBanner(model: model)
            bar
            // A subscription's window at 90%, or its limit reached, while runs used it: about a subscription, not a
            // project, so under the line across all projects rather than in a column (#645).
            DashboardLimitNotices(model: model, short: height < Self.shortHeight)
            if watched.isEmpty {
                empty
            } else {
                GeometryReader { space in
                    ScrollViewReader { scroller in
                        columns(in: space.size.width)
                            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                            .onChange(of: model.dashboardKeys.columnAsks) { _, _ in
                                let number = model.dashboardKeys.column
                                guard number >= 1, number <= watched.count else { return }
                                let project = watched[number - 1]
                                if foldedColumns.contains(project.id) { setFolded(false, project.id) }
                                withAnimation(.easeOut(duration: 0.2)) { scroller.scrollTo(project.id) }
                                focus = (project.id, focus.asks + 1)
                            }
                            .onChange(of: model.dashboardKeys.firstNeedAsks) { _, _ in
                                let ids = Set(watched.map(\.id))
                                guard let first = engine.needs.first(where: { $0.projectId.map(ids.contains) == true })?.projectId else { return }
                                if foldedColumns.contains(first) { setFolded(false, first) }
                                withAnimation(.easeOut(duration: 0.2)) { scroller.scrollTo(first) }
                            }
                    }
                }
            }
        }
        .background(Theme.window)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
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
    /// draws them (docs/design/projects-drafts.html, screen 5), and never narrower than 290 points, so that more than
    /// fit scroll sideways rather than squeeze. The window is never asked for more room either way.
    static func columnWidth(_ count: Int, in width: CGFloat) -> CGFloat {
        guard count > 0, width > 0 else { return minimumColumnWidth }
        return max(minimumColumnWidth, (width / CGFloat(count)).rounded(.down))
    }

    /// The narrowest a column gets before the row scrolls instead.
    static let minimumColumnWidth: CGFloat = 290
    /// A column folded to a strip with its name and badge.
    static let foldedWidth: CGFloat = 40

    /// The columns side by side, scrolling sideways when they are more than fit.
    private func columns(in available: CGFloat) -> some View {
        let shown = watched
        let open = shown.filter { !foldedColumns.contains($0.id) }.count
        let width = Self.columnWidth(open, in: available - CGFloat(shown.count - open) * Self.foldedWidth)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, project in
                    column(project, index: index, width: width)
                        .id(project.id)
                }
            }
        }
    }

    /// A column, or the strip it is folded to, with what moves it: dragging its header onto another's, or its menu.
    @ViewBuilder
    private func column(_ project: ProjectRow, index: Int, width: CGFloat) -> some View {
        let folded = foldedColumns.contains(project.id)
        let ids = watched.map(\.id)
        let arrange = ColumnArrangement(
            number: index + 1,
            canMoveLeft: index > 0,
            canMoveRight: index < ids.count - 1,
            fold: { setFolded(!folded, project.id) },
            move: { offset in
                let target = index + offset
                guard target >= 0, target < ids.count else { return }
                // Before the column now at the target, or, moving right, before the one after it.
                let before = offset < 0 ? ids[target] : (target + 1 < ids.count ? ids[target + 1] : nil)
                reorder(project.id, before: before)
            },
            dropped: { dragged in
                guard dragged != project.id, ids.contains(dragged) else { return false }
                // Dropped on a column to its right, it goes after that column; to its left, before it.
                let from = ids.firstIndex(of: dragged) ?? 0
                let before = from < index ? (index + 1 < ids.count ? ids[index + 1] : nil) : project.id
                reorder(dragged, before: before)
                return true
            }
        )
        Group {
            if folded {
                FoldedColumn(model: model, project: project, arrange: arrange)
                    .frame(width: Self.foldedWidth)
            } else {
                DashboardColumn(
                    model: model, project: project, visible: onScreen.contains(project.id), arrange: arrange,
                    focusRequest: focus.project == project.id ? focus.asks : 0
                )
                .frame(width: width)
                .onScrollVisibilityChange(threshold: 0.05) { shown in
                    if shown { onScreen.insert(project.id) } else { onScreen.remove(project.id) }
                }
            }
        }
        .frame(minHeight: 0, maxHeight: .infinity)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
        // Tab moves among the column's own cards and fields before it goes on to the next column.
        .focusSection()
    }

    /// Puts one column before another, or last, and remembers the whole order.
    private func reorder(_ id: String, before: String?) {
        let next = DashboardArrangement.moving(id, before: before, in: watched.map(\.id))
        // Projects not watched now keep their places after the watched ones.
        let rest = order.filter { !next.contains($0) }
        withAnimation(.easeOut(duration: 0.2)) { order = next + rest }
        DashboardArrangement.saveOrder(order)
    }

    private func setFolded(_ folded: Bool, _ id: String) {
        if folded { foldedColumns.insert(id); onScreen.remove(id) } else { foldedColumns.remove(id) }
        DashboardArrangement.setFolded(folded, for: id)
    }

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
                AllProjectsLine(model: model, projects: watched)
            }
            Spacer(minLength: 0)
            StopAllButton(model: model, projects: Set(watched.map(\.id)))
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
    /// What folds and moves the column.
    let arrange: ColumnArrangement
    /// Goes up when the keyboard is asked for in this column's field (⌥⌘ and its number).
    var focusRequest = 0

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
    /// Whether Finished today is unfolded; folded as the column appears, with its count showing (#618).
    @State private var finishedOpen = false

    private var engine: EngineClient { model.engine }
    private var needs: [NeedItem] { engine.needs.filter { $0.projectId == project.id } }
    private var runs: [ActivityRun] { engine.activity.filter { $0.projectId == project.id && $0.chat != true } }
    private var waking: Bool { project.settings?.wakeOnReports ?? false }
    private var live: ProjectLive { engine.projectStore.live(project.id) }
    private var reports: [ProjectReport] { ProjectReports(engine.extras["reports"]?["projects"]?[project.id]).items }
    /// The open pull requests of a project whose work is a GitHub repository, newest first.
    private var pulls: [GitHubPull] {
        project.repository == nil ? [] : WorkListings.github(engine, project: project.id).openPulls
    }

    var body: some View {
        VStack(spacing: 0) {
            ColumnHeader(model: model, project: project, arrange: arrange)
            ProjectVitals(model: model, project: project)
            needsSection
            Divider().overlay(Theme.line)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    workingSection
                    finishedSection
                    mergeSection
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 0)
            // The window takes at most a third or so of what the column has beside its header, vitals and field, so that
            // at the window's smallest size a card and a working row still show above it.
            OrchestratorPane(model: model, project: project, visible: visible, tallest: max(DashboardPaneLayout.minimumHeight, (height - 170) * 0.35), focusRequest: focusRequest)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { paneHeight = $0 }
        }
        .background(Theme.window)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
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

    // MARK: Finished today

    /// The runs that ended today, folded by default with their count: the Now tab's own rows (#618).
    @ViewBuilder
    private var finishedSection: some View {
        if !reports.isEmpty {
            let unread = reports.filter { $0.deliveredBy == nil }.count
            VStack(alignment: .leading, spacing: 8) {
                SectionToggle(title: "Finished today", count: reports.count, note: unread > 0 ? "\(unread) not read yet" : nil, open: $finishedOpen)
                if finishedOpen {
                    ForEach(reports) { report in
                        FinishedRow(engine: engine, report: report)
                    }
                }
            }
        }
    }

    // MARK: To merge

    /// The pull requests open on the project's repository, only when there are any: each with its checks and its review
    /// in a word, opening it on the Work tab when clicked. Nothing is merged from here (#618).
    @ViewBuilder
    private var mergeSection: some View {
        if !pulls.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("To merge").sectionLabel()
                    Text(String(pulls.count)).font(Theme.label).monospacedDigit().foregroundStyle(Theme.tx3)
                    Spacer(minLength: 0)
                    if let read = WorkListings.github(engine, project: project.id).readAt {
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            Text("read \(LimitsFormat.ago(read, now: context.date))")
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.tx3)
                                .help("As GitHub was last read for this project. pi² reads it again while the project's Now or Work tab shows, or when an agent asks.")
                        }
                    }
                }
                ForEach(pulls.prefix(5)) { pull in
                    PullLine(pull: pull) {
                        model.hubs.openPull(pull.number, for: project.id)
                        model.showProject(project.id, tab: .work)
                    }
                }
                if pulls.count > 5 {
                    Button("\(pulls.count - 5) more on the Work tab") { model.showProject(project.id, tab: .work) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.acc)
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

// MARK: - A column's header, and the strip it folds to

/// What folds and moves a column (#618): its number, for ⌥⌘ and the number, whether it can move either way, and what
/// folding, moving and a header dropped on it do.
struct ColumnArrangement {
    let number: Int
    let canMoveLeft: Bool
    let canMoveRight: Bool
    let fold: () -> Void
    /// Moves the column by one place: -1 left, 1 right.
    let move: (Int) -> Void
    /// Another column's header dropped on this one, by its project id: whether it moved.
    let dropped: (String) -> Bool
}

/// The project's name with its badge, the button to its hub and the one that folds the column. The header is what the
/// person drags to put the columns in their own order; its menu moves the column a place either way too.
private struct ColumnHeader: View {
    let model: AppModel
    let project: ProjectRow
    let arrange: ColumnArrangement
    @State private var targeted = false

    private var engine: EngineClient { model.engine }

    var body: some View {
        HStack(spacing: 8) {
            ProjectMark(name: project.name, color: engine.agent(project.orchestratorId)?.color, size: 18)
            Text(project.name)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.tx)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 6)
            ColumnBadge(engine: engine, project: project)
            Button("Open") { model.showProject(project.id) }
                .buttonStyle(.piGhost)
                .fixedSize()
                .help("Open the project’s own hub, beside the Dashboard")
            Button("Fold the Column", systemImage: "chevron.left.2", action: arrange.fold)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.tx3)
                .help("Fold the column to a narrow strip with its name")
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(targeted ? Theme.acc.opacity(0.18) : Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .contentShape(.rect)
        .draggable(DashboardColumnDrag(id: project.id)) {
            Text(project.name)
                .font(.system(size: 12.5, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Theme.panel, in: .rect(cornerRadius: 6))
        }
        .dropDestination(for: DashboardColumnDrag.self) { dragged, _ in
            guard let first = dragged.first else { return false }
            return arrange.dropped(first.id)
        } isTargeted: { targeted = $0 }
        .contextMenu(previewAs: "Column \(project.name)") {
            ColumnMenu(arrange: arrange)
        }
        .help("Drag to put the columns in your own order")
    }
}

/// A column's menu: move it a place either way, or fold it.
private struct ColumnMenu: View {
    let arrange: ColumnArrangement

    var body: some View {
        Button("Move Left") { arrange.move(-1) }
            .disabled(!arrange.canMoveLeft)
        Button("Move Right") { arrange.move(1) }
            .disabled(!arrange.canMoveRight)
        Divider()
        Button("Fold the Column", action: arrange.fold)
    }
}

/// A column dragged by its header: only its project's id travels, and only within the app.
struct DashboardColumnDrag: Codable, Transferable {
    let id: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}

/// What a column's badge says: how many things wait for the person, or how many agents work, or idle.
private struct ColumnBadge: View {
    let engine: EngineClient
    let project: ProjectRow
    private var live: ProjectLive { engine.projectStore.live(project.id) }

    var body: some View {
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
    }
}

/// A column folded to a narrow strip: its mark, its badge and its name running down, which unfold it when clicked. It
/// asks the engine for nothing, as a column out of sight does.
private struct FoldedColumn: View {
    let model: AppModel
    let project: ProjectRow
    let arrange: ColumnArrangement
    @State private var targeted = false

    private var engine: EngineClient { model.engine }
    private var live: ProjectLive { engine.projectStore.live(project.id) }

    var body: some View {
        Button(action: arrange.fold) {
            VStack(spacing: 10) {
                ProjectMark(name: project.name, color: engine.agent(project.orchestratorId)?.color, size: 18)
                if live.needs > 0 {
                    Tag("\(live.needs)", .warn).fixedSize()
                } else if live.working > 0 {
                    Spinner(size: 10)
                }
                Text(project.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.tx2)
                    .lineLimit(1)
                    .fixedSize()
                    .rotationEffect(.degrees(90))
                    .frame(width: 18, height: 160, alignment: .center)
                    .clipped()
                Spacer(minLength: 0)
            }
            .padding(.top, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(targeted ? Theme.acc.opacity(0.18) : Theme.panel)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Unfold \(project.name)")
        .accessibilityLabel("\(project.name), folded\(live.needs > 0 ? ", \(live.needs) waiting on you" : "")")
        .draggable(DashboardColumnDrag(id: project.id)) {
            Text(project.name).font(.system(size: 12.5, weight: .semibold)).padding(6)
        }
        .dropDestination(for: DashboardColumnDrag.self) { dragged, _ in
            guard let first = dragged.first else { return false }
            return arrange.dropped(first.id)
        } isTargeted: { targeted = $0 }
        .contextMenu(previewAs: "Column \(project.name)") {
            Button("Unfold the Column", action: arrange.fold)
            Divider()
            Button("Move Left") { arrange.move(-1) }
                .disabled(!arrange.canMoveLeft)
            Button("Move Right") { arrange.move(1) }
                .disabled(!arrange.canMoveRight)
        }
    }
}

// MARK: - A section that folds, and a pull request's line

/// A section's name and count, with a chevron that folds it.
private struct SectionToggle: View {
    let title: String
    let count: Int
    var note: String? = nil
    @Binding var open: Bool

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.tx3)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 10)
                Text(title).sectionLabel()
                Text(String(count)).font(Theme.label).monospacedDigit().foregroundStyle(Theme.tx3)
                if let note {
                    Text(note).font(.system(size: 10.5)).foregroundStyle(Theme.warn).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count)\(note.map { ", \($0)" } ?? "")")
        .accessibilityValue(open ? "shown" : "folded")
        .help(open ? "Fold \(title)" : "Show \(title)")
    }
}

/// One open pull request: its number and title, its checks and its review in a word. Clicking it opens it on the
/// project's Work tab.
private struct PullLine: View {
    let pull: GitHubPull
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("#\(pull.number)").font(Theme.mono).foregroundStyle(Theme.tx3).fixedSize()
                    Text(pull.title).font(.system(size: 12)).foregroundStyle(Theme.tx).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 6) {
                    if pull.draft { Text("draft").foregroundStyle(Theme.tx3) }
                    Text(checks).foregroundStyle(checksColour)
                    if let finding = pull.newestFinding {
                        Text("·").foregroundStyle(Theme.tx3)
                        Text("\(finding.agentName) \(GitHubPull.verdictWords(finding.verdict))")
                            .foregroundStyle(finding.verdict == "approve" ? Theme.ok : finding.verdict == "changes" ? Theme.warn : Theme.tx3)
                            .lineLimit(1)
                    } else {
                        Text("·").foregroundStyle(Theme.tx3)
                        Text("not reviewed").foregroundStyle(Theme.tx3)
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11))
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .panel()
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Open pull request #\(pull.number) on the Work tab")
    }

    /// The checks in a word.
    private var checks: String {
        switch pull.checks {
        case "passing": "checks pass"
        case "failing": pull.failingChecks.count == 1 ? "1 check fails" : "\(pull.failingChecks.count) checks fail"
        case "pending": "checks running"
        default: "no checks"
        }
    }

    private var checksColour: Color {
        switch pull.checks {
        case "passing": Theme.ok
        case "failing": Theme.bad
        default: Theme.tx3
        }
    }
}

// MARK: - Across all projects

/// Stop All, at the end of the line across all projects while anyone works in the projects watched (#645): it asks first,
/// naming how many runs it stops (`stopAllConfirmation`).
private struct StopAllButton: View {
    let model: AppModel
    let projects: Set<String>

    var body: some View {
        let count = RunStopping.runs(in: projects, engine: model.engine).count
        if count > 0 {
            Button("Stop All", systemImage: "stop.fill") { model.stoppingAll = StopAllRequest(projects: projects) }
                .labelStyle(.titleAndIcon)
                .buttonStyle(PiButtonStyle(kind: .danger, compact: true))
                .fixedSize()
                .help(count == 1 ? "Stop the 1 run in the projects shown here" : "Stop the \(count) runs in the projects shown here")
        }
    }
}

/// The limit notices, each one line until unfolded, under the line across all projects (#645): the Inbox's own cards,
/// with their Dismiss and Show Usage. However many there are, they scroll within at most a few lines' room, and in a
/// short window one line's, with a line saying how many more there are, so that the columns keep the window.
private struct DashboardLimitNotices: View {
    let model: AppModel
    let short: Bool
    @State private var height: CGFloat = 0
    @State private var first: CGFloat = 0

    private var notices: [PlanLimits.Notice] { PlanLimits(model.engine.extras["limits"])?.notices ?? [] }

    var body: some View {
        let notices = notices
        if !notices.isEmpty {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(Array(notices.enumerated()), id: \.element.id) { index, notice in
                            LimitNoticeCard(
                                engine: model.engine, notice: notice,
                                open: { OpenInProjects.open($0, model: model) },
                                showUsage: { model.selection = .usage },
                                foldable: true
                            )
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if index == 0 { first = $0 } }
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
                }
                .frame(height: min(max(height, 1), short ? first + 12 : 200))
                if short, notices.count > 1, height > first + 12 {
                    Text(notices.count == 2 ? "1 more notice · Scroll to see it" : "\(notices.count - 1) more notices · Scroll to see all")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tx3)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 4)
                }
            }
            .background(Theme.window)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        }
    }
}

/// One line across every project watched, at the top of the Dashboard (#618): how many things need the person in all
/// (which brings the first into view, ⌥⌘0), how many agents are working, what was spent today in all, and how the plans'
/// windows stand, as Usage shows each subscription's, with a mark while a provider refuses for its limit and until when.
private struct AllProjectsLine: View {
    let model: AppModel
    let projects: [ProjectRow]

    private var engine: EngineClient { model.engine }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let ids = Set(projects.map(\.id))
            let needs = engine.needs.filter { $0.projectId.map(ids.contains) == true }.count
            let working = engine.activity.filter { $0.projectId.map(ids.contains) == true && $0.chat != true }.count
            let spent = engine.usage?.today.cost ?? 0
            let plans = Self.plans(PlanLimits(engine.extras["limits"]), runs: engine.activity, now: context.date)
            ViewThatFits(in: .horizontal) {
                line(needs: needs, working: working, spent: spent, plans: plans, short: false)
                line(needs: needs, working: working, spent: spent, plans: plans, short: true)
                line(needs: needs, working: working, spent: spent, plans: [], short: true)
                line(needs: needs, working: working, spent: nil, plans: [], short: true)
            }
            .font(.system(size: 11.5))
            .lineLimit(1)
        }
    }

    private func line(needs: Int, working: Int, spent: Double?, plans: [Plan], short: Bool) -> some View {
        HStack(spacing: 6) {
            Button(needs == 1 ? "1 needs you" : "\(needs) need you") { model.dashboardKeys.showFirstNeed() }
                .buttonStyle(.plain)
                .foregroundStyle(needs > 0 ? Theme.warn : Theme.tx3)
                .disabled(needs == 0)
                .help("Bring the first thing that needs you into view (⌥⌘0)")
                .fixedSize()
            dot
            Text("\(working) working").foregroundStyle(Theme.tx2).fixedSize()
            if let spent {
                dot
                Text("\(Formats.cost(spent)) today").foregroundStyle(Theme.tx2).fixedSize()
                    .help("Spent today in all, as Usage counts it")
            }
            ForEach(plans) { plan in
                dot
                HStack(spacing: 4) {
                    if plan.refusing != nil {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
                    }
                    Text(short ? plan.short : plan.long).foregroundStyle(plan.refusing != nil ? Theme.warn : plan.high ? Theme.warn : Theme.tx2)
                }
                .fixedSize()
                .help(plan.help)
            }
        }
    }

    private var dot: some View { Text("·").foregroundStyle(Theme.tx3) }

    /// A subscription's windows in a few words, and whether its provider refuses runs for its limit now.
    struct Plan: Identifiable {
        let id: String
        let long: String
        let short: String
        let help: String
        let high: Bool
        let refusing: Date?
    }

    /// Each subscription that reports windows, or whose provider is refusing runs: "Anthropic Max 5-hour 42%, week 61%",
    /// or "Anthropic refuses until 14:05".
    static func plans(_ limits: PlanLimits?, runs: [ActivityRun], now: Date) -> [Plan] {
        let reached = (limits?.notices ?? []).filter { $0.currentStage == "reached" }
        var plans: [Plan] = []
        for provider in limits?.providers ?? [] {
            let windows = (provider.windows ?? []).filter { $0.resetsAt.map { LimitsFormat.date($0) > now } ?? true }
            let notice = reached.first { $0.provider == provider.id }
            let until = notice?.until.map(LimitsFormat.date)
            guard !windows.isEmpty || notice != nil else { continue }
            let name = "\(provider.name)\(provider.plan.map { " \($0)" } ?? "")"
            let parts = windows.map { "\(shortLabel($0.label)) \(LimitsFormat.percent(min(max($0.usedPercent, 0), 100)))%" }
            let time = until.map { $0.formatted(date: .omitted, time: .shortened) }
            let refusing = notice.map { _ in until ?? now }
            let refusal = notice == nil ? nil : (time.map { "refuses until \($0)" } ?? "refuses for its limit")
            let long = "\(name) \(refusal ?? parts.joined(separator: ", "))"
            let top = windows.max { $0.usedPercent < $1.usedPercent }
            let short = refusal.map { "\(provider.name) \($0)" } ?? "\(provider.name) \(top.map { "\(LimitsFormat.percent(min(max($0.usedPercent, 0), 100)))%" } ?? "")"
            let help = (windows.map { window in
                let reset = window.resetsAt.map { ", resets in \(LimitsFormat.duration(LimitsFormat.date($0).timeIntervalSince(now)))" } ?? ""
                return "\(window.label): \(LimitsFormat.percent(min(max(window.usedPercent, 0), 100)))% used\(reset)"
            } + (refusal.map { ["\(provider.name) \($0); the runs on it wait and carry on by themselves."] } ?? [])).joined(separator: "\n")
            plans.append(Plan(id: provider.id, long: long, short: short, help: "\(name)\n\(help)", high: (top?.usedPercent ?? 0) >= 80, refusing: refusing))
        }
        // A provider refusing that has no plan here (a key's rate limit): from the runs that wait on it.
        let named = Set(plans.map(\.id))
        let waits = runs.compactMap(\.limit).filter { $0.kind == "rate_limit" }
        for wait in waits where !named.contains(wait.provider) && !plans.contains(where: { $0.id == "wait:\(wait.provider)" }) {
            let latest = waits.filter { $0.provider == wait.provider }.map(\.until).max() ?? wait.until
            let time = LimitsFormat.date(latest).formatted(date: .omitted, time: .shortened)
            plans.append(Plan(id: "wait:\(wait.provider)", long: "\(wait.provider) refuses until \(time)", short: "\(wait.provider) until \(time)",
                              help: "\(wait.provider) refused for its rate limit; the runs on it wait until \(time) and carry on by themselves.",
                              high: true, refusing: LimitsFormat.date(latest)))
        }
        return plans
    }

    /// "5-hour", "week": a window's label made short for the line.
    static func shortLabel(_ label: String) -> String {
        let lower = label.lowercased()
        if lower.hasPrefix("this week") { return "week" }
        if lower.contains("5-hour") || lower.contains("5 hour") || lower.contains("five-hour") { return "5-hour" }
        return label.split(separator: " ").prefix(2).joined(separator: " ").lowercased()
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
