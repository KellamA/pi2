import EngineKit
import PiModels
import SwiftUI

/// A project's work list (docs/design/iphone.md, "The Work tab, and a pull request with its diff"): the list in the
/// Mac's states behind a segmented control, the open pull requests above the open work when a repository is attached,
/// Give on what nobody has, and New Work. Drawn as a screen of its own, or inline as the hub's Work tab, where the hub's
/// bar is the screen's and New Work moves under the control.
struct WorkListScreen: View {
    let project: ProjectRow
    let listing: WorkListing
    let agents: [AgentProfile]
    /// Debug builds only: what sample this shows in place of the Mac's list, said at its top.
    var sample: String?

    @Environment(AppSession.self) private var session
    @Environment(\.placement) private var placement
    @Environment(\.openRoute) private var openRoute
    @State private var filter: WorkFilter = .open
    @State private var desk = WorkDesk()
    @State private var giving: WorkItem?
    @State private var filing = false
    @State private var refreshing = false

    var body: some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let problem = desk.problem {
                    WorkProblemBar(words: problem) { desk.problem = nil }
                }
            }
            .sheet(item: $giving) { item in
                WorkGiveSheet(item: item, noun: listing.noun, agents: agents, holding: holding) { agent in
                    Task { await desk.assign(session.engine, project: project.id, item: item, to: agent) }
                }
            }
            .sheet(isPresented: $filing) {
                WorkComposer(mode: .new, noun: listing.noun, destination: destination) { title, text in
                    await WorkRequests.create(session.engine, project: project.id, title: title, text: text)
                }
            }
            .workHeldStart(desk: desk, engine: session.engine, project: project.id)
            .modifier(WorkScreenChrome(placement: placement, title: "Work") {
                Button("New \(listing.noun == "issue" ? "Issue" : "Work")", systemImage: "plus", action: beginFiling)
                    .disabled(listing.troubled)
            })
            #if DEBUG
            .task { await debugAct() }
            #endif
    }

    // MARK: - The list

    @ViewBuilder
    private var content: some View {
        if listing.firstRead {
            VStack(spacing: 12) {
                ProgressView()
                Text(loadingWords)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        } else {
            let sections = listing.sections(filter)
            let list = List {
                if let trouble = listing.troubleWords() {
                    Section {
                        Label(trouble, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .symbolRenderingMode(.multicolor)
                    }
                }
                if !listing.unknown.isEmpty, filter == .open {
                    Section {
                        ForEach(listing.unknown) { write in
                            WorkUnknownCard(write: write, busy: desk.settling.contains(write.intent)) { happened in
                                Task { await desk.settle(session.engine, project: project.id, write: write, happened: happened) }
                            }
                        }
                    }
                }
                ForEach(sections) { section in
                    Section {
                        ForEach(section.rows) { row in
                            rowView(row)
                        }
                    } header: {
                        Text("\(section.name) · \(section.rows.count)")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if sections.isEmpty, listing.unknown.isEmpty || filter != .open { empty }
            }
            // Pulling the list down reads a repository again; the list pi² keeps comes as it changes, with nothing to read.
            if listing.onGitHub {
                list.refreshable { await refresh() }
            } else {
                list
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: WorkRowEntry) -> some View {
        switch row {
        case .item(let listed):
            let change = desk.pending[listed.id]
            let item = listed.showing(change)
            WorkItemRow(
                item: item, holder: session.engine.agent(item.holderAgentId), pending: change?.word, noun: listing.noun,
                canGive: listed.givable && change == nil && !agents.isEmpty && !listing.troubled,
                open: { openRoute(.work(project: project.id, item: listed.id)) },
                give: { giving = listed }
            )
        case .pull(let pull):
            WorkPullRow(pull: pull) { openRoute(.pullRequest(project: project.id, number: pull.number)) }
        }
    }

    /// The control, where the list comes from, and, inline, New Work: under the screen's bar or the hub's.
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Show", selection: $filter) {
                ForEach(WorkFilter.allCases) { filter in
                    Text(filter.name).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            WorkFlow(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: listing.onGitHub ? "chevron.left.forwardslash.chevron.right" : "checklist")
                        .accessibilityHidden(true)
                    Text(sourceWords)
                    if listing.reading || refreshing {
                        ProgressView().controlSize(.mini)
                            .accessibilityLabel("Reading it again from GitHub")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                if placement == .inline {
                    Button("New \(listing.noun == "issue" ? "Issue" : "Work")", systemImage: "plus", action: beginFiling)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(listing.troubled)
                }
            }
            if let sample {
                Text("Sample data (\(sample)), drawn by a debug build: not from your Mac.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 10)
        // A bar that stays put while the list scrolls: at the largest sizes it would take the screen from the list.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var sourceWords: String {
        switch listing.source {
        case .kept: return "Kept by pi²"
        case .github(let repository):
            guard let readAt = listing.readAt else { return repository }
            return "\(repository) · read \(WorkTime.ago(readAt))"
        }
    }

    private var loadingWords: String {
        switch listing.source {
        case .kept: "Reading the work list from your Mac…"
        case .github(let repository):
            "Reading \(repository) for the first time. Its issues and pull requests show here as soon as GitHub answers."
        }
    }

    /// Where a new piece goes, under the form.
    private var destination: String {
        switch listing.source {
        case .kept: "Kept by pi² in \(project.name)'s list. Give it to an agent and it starts working on it; the orchestrator adds work here too."
        case .github(let repository): "Filed as an issue in \(repository), as you."
        }
    }

    @ViewBuilder
    private var empty: some View {
        switch filter {
        case .open:
            if listing.onGitHub {
                ContentUnavailableView(listing.troubled ? "Nothing was read" : "Nothing open", systemImage: "checklist", description: Text(listing.troubled
                    ? "When GitHub answers, this project's issues and pull requests show here."
                    : "This repository has no open issues and no open pull requests. The agents file and work on them with their work tool."))
            } else {
                ContentUnavailableView {
                    Label(listing.items.isEmpty ? "No work yet" : "Nothing open", systemImage: "checklist")
                } description: {
                    Text("A piece of work is a task for this project, kept in a list pi² itself holds. Give one to an agent and it starts working on it; the orchestrator adds work here too.")
                } actions: {
                    Button("New Work", action: beginFiling)
                        .buttonStyle(.bordered)
                }
            }
        case .waiting:
            ContentUnavailableView("Nothing waiting", systemImage: "hourglass",
                                   description: Text("No \(listing.noun) waits or is blocked. What an agent cannot go on with shows here."))
        case .done:
            ContentUnavailableView("Nothing closed", systemImage: "checkmark.circle",
                                   description: Text("What is done or dropped shows here."))
        }
    }

    /// The pieces each agent holds now, for the give sheet.
    private var holding: [String: [WorkItem]] {
        Dictionary(grouping: listing.items.filter { $0.held && $0.holderAgentId != nil }) { $0.holderAgentId ?? "" }
    }

    private func refresh() async {
        refreshing = true
        desk.problem = await WorkRequests.refresh(session.engine, project: project.id)
        refreshing = false
    }

    private func beginFiling() {
        filing = true
    }

    #if DEBUG
    /// What `PI2_WORK_ACT` asks of the list once it shows (`WorkDebugAct`).
    private func debugAct() async {
        try? await Task.sleep(for: .seconds(1))
        if let filter = WorkDebugAct.filter { self.filter = filter }
        if WorkDebugAct.take("new") { filing = true }
        if WorkDebugAct.take("give"), let item = listing.items.first(where: { $0.givable }) {
            if let name = WorkDebugAct.argument("give"), let agent = agents.first(where: { $0.name == name }) {
                await desk.assign(session.engine, project: project.id, item: item, to: agent)
            } else {
                giving = item
            }
        }
    }
    #endif
}

/// What only a whole screen has: its title in the bar and its action there. Inline, as the hub's Work tab, the hub's
/// bar is the screen's, so neither is set.
struct WorkScreenChrome<Action: View>: ViewModifier {
    let placement: Placement
    let title: String
    @ViewBuilder let action: Action

    func body(content: Content) -> some View {
        if placement == .screen {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) { action }
                }
        } else {
            content
        }
    }
}

extension View {
    /// The question a start the project's limit held asks, in the Mac's words (`HeldStartCard`): Start Anyway confirms
    /// that one start (`confirmLimit`), Leave It lets it be.
    func workHeldStart(desk: WorkDesk, engine: EngineSession<MessageField>, project: String) -> some View {
        alert(desk.held?.title ?? "", isPresented: Binding(get: { desk.held != nil }, set: { if !$0 { desk.held = nil } }),
              presenting: desk.held) { held in
            Button("Start Anyway") {
                Task { await desk.assign(engine, project: project, item: held.item, to: held.agent, confirming: held.limit) }
            }
            Button("Leave It", role: .cancel) { desk.held = nil }
        } message: { held in
            Text(held.message)
        }
    }
}
