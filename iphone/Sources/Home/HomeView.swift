
import PiModels
import SwiftUI

/// The projects list, the app's root once a Mac is paired or the demo is on (docs/design/iphone.md, "The projects list,
/// with what needs the person at the top"): the connection bar, Needs you, the Dashboard, the projects with the badges
/// of the Mac's sidebar, chats, and More; search over all of it. Everything in it is read from the session's client;
/// what it changes it asks the Mac's engine for (`HomeActions`), and shows the engine's refusal when there is one.
struct HomeView: View {
    init() {}

    @Environment(AppSession.self) private var session
    @Environment(\.openRoute) private var openRoute
    @State private var actions = HomeActions()
    @State private var messages = HomeMessageSearch()
    @State private var query = ""
    @State private var renaming: HomeProject?
    @State private var newName = ""
    @State private var allChats = false

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    HomeConnectionBar()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    lists
                } else {
                    HomeSearchResults(query: query, messages: messages)
                }
            }
            #if DEBUG
            .task { await debugLaunch(proxy) }
            #endif
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .navigationTitle("pi²")
        .searchable(text: $query, prompt: Text("Projects, conversations, messages"))
        .onChange(of: query) { _, text in
            messages.update(text, in: session.engine)
        }
        .alert(actions.failure?.title ?? "", isPresented: Binding(
            get: { actions.failure != nil },
            set: { if !$0 { actions.failure = nil } }
        ), presenting: actions.failure) { _ in
            Button("OK", role: .cancel) {}
        } message: { failure in
            Text(failure.message)
        }
        .alert("Rename Project", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        ), presenting: renaming) { project in
            TextField("Name", text: $newName)
            Button("Rename") {
                let name = newName
                Task { await actions.rename(project, to: name, in: session.engine) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    #if DEBUG
    /// `PI2_HOME` in a debug build's environment (`HomeDebugLaunch`), once the projects are in.
    private func debugLaunch(_ proxy: ScrollViewProxy) async {
        guard HomeDebugLaunch.value != nil else { return }
        let end = Date(timeIntervalSinceNow: 20)
        while session.engine.projects.isEmpty, Date() < end {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if let words = HomeDebugLaunch.search { query = words }
        if let section = HomeDebugLaunch.scroll {
            try? await Task.sleep(for: .milliseconds(300))
            proxy.scrollTo(section, anchor: .top)
        }
        if let name = HomeDebugLaunch.archive, let project = HomeLists.projects(session.engine).first(where: { $0.name == name }) {
            archive(project)
        }
    }
    #endif

    // MARK: - The lists

    @ViewBuilder private var lists: some View {
        let engine = session.engine
        let projects = HomeLists.projects(engine)
        let asOf = asOf
        let loaded = loaded
        if !engine.needs.isEmpty {
            Section {
                RouteView(.needs(), placement: .inline)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            } header: {
                header(String(localized: "Needs you · \(engine.needs.count)"), asOf: asOf)
            }
        }
        Section {
            Button { openRoute(.dashboard()) } label: {
                HomeMoreRow(title: "Dashboard", icon: "square.grid.2x2") {
                    if !engine.needs.isEmpty {
                        Text(engine.needs.count == 1 ? "1 needs you" : "\(engine.needs.count) need you").foregroundStyle(.orange)
                    } else if loaded {
                        Text(projects.count == 1 ? "1 project" : "\(projects.count) projects")
                    }
                }
            }
            .tint(.primary)
        }
        Section {
            if projects.isEmpty {
                waiting(loaded: loaded)
            }
            ForEach(projects) { project in
                Button { openRoute(.project(project.id)) } label: {
                    HomeProjectRow(project: project)
                }
                .tint(.primary)
                .opacity(asOf == nil ? 1 : 0.6)
                .swipeActions(edge: .trailing) {
                    Button { archive(project) } label: { Label("Archive", systemImage: "archivebox") }
                        .tint(.indigo)
                }
                .contextMenu { projectMenu(project) }
                .accessibilityHint("Opens the project's conversation with its orchestrator")
            }
        } header: {
            header(String(localized: "Projects"), asOf: asOf)
        }
        chats(asOf: asOf)
        more
    }

    /// Whether the engine has sent its lists yet: until then a count of nothing would be wrong.
    private var loaded: Bool {
        session.engine.hasLoadedLibrary || !session.engine.projects.isEmpty
    }

    /// When what is shown was last heard from the Mac, while it cannot be reached: everything shows as it was then.
    private var asOf: Date? {
        if case .outOfReach(let seen) = session.connection { return seen ?? .distantPast }
        return nil
    }

    private func header(_ title: String, asOf: Date?) -> some View {
        let seen = asOf.flatMap { $0 == .distantPast ? nil : HomeTime.lastSeen($0) }
        return Text(seen.map { String(localized: "\(title) · as of \($0)") } ?? title)
    }

    /// What the projects' section says while it has none to list.
    @ViewBuilder private func waiting(loaded: Bool) -> some View {
        let mac = session.macName ?? String(localized: "your Mac")
        switch (session.connection, loaded) {
        case (_, true):
            Text("No projects yet. Make one on your Mac with New Project, from a folder.")
                .foregroundStyle(.secondary)
        case (.notPaired, _):
            Text("No Mac paired.").foregroundStyle(.secondary)
        case (.outOfReach, _):
            Text("Nothing from \(mac) yet. Its projects show here once it can be reached.")
                .foregroundStyle(.secondary)
        default:
            HStack(spacing: 10) {
                ProgressView()
                Text("Loading the projects…").foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder private func projectMenu(_ project: HomeProject) -> some View {
        if project.orchestratorWorking {
            Button("Stop the Orchestrator", systemImage: "stop.circle") {
                Task { await actions.stopOrchestrator(of: project, in: session.engine) }
            }
            Divider()
        }
        Button("Rename…", systemImage: "pencil") {
            newName = project.name
            renaming = project
        }
        Button("Archive", systemImage: "archivebox") { archive(project) }
    }

    private func archive(_ project: HomeProject) {
        Task { await actions.archive(project, in: session.engine) }
    }

    // MARK: Chats

    @ViewBuilder private func chats(asOf: Date?) -> some View {
        let chats = HomeLists.chats(session.engine.conversations)
        let pinned = chats.count(where: \.isPinned)
        let limit = max(HomeLists.chatsShown, pinned)
        let shown = allChats ? chats : Array(chats.prefix(limit))
        Section {
            ForEach(shown) { chat in
                Button { openRoute(.conversation(chat.id)) } label: {
                    HomeChatRow(chat: chat)
                }
                .tint(.primary)
                .opacity(asOf == nil ? 1 : 0.6)
                .swipeActions(edge: .leading) {
                    Button { pin(chat, !chat.isPinned) } label: {
                        Label(chat.isPinned ? "Unpin" : "Pin", systemImage: chat.isPinned ? "pin.slash" : "pin")
                    }
                    .tint(.orange)
                }
                .swipeActions(edge: .trailing) {
                    Button { archive(chat) } label: { Label("Archive", systemImage: "archivebox") }
                        .tint(.indigo)
                }
                .contextMenu {
                    Button(chat.isPinned ? "Unpin" : "Pin", systemImage: chat.isPinned ? "pin.slash" : "pin") { pin(chat, !chat.isPinned) }
                    Button("Archive", systemImage: "archivebox") { archive(chat) }
                }
            }
            if chats.count > limit {
                Button(allChats ? "Show Fewer" : "Show All \(chats.count) Chats") {
                    withAnimation { allChats.toggle() }
                }
            }
            Button {
                Task {
                    if let id = await actions.newChat(in: session.engine) { openRoute(.conversation(id)) }
                }
            } label: {
                Label("New Chat", systemImage: "square.and.pencil")
            }
            .disabled(actions.makingChat || session.engine.status != .connected)
        } header: {
            header(String(localized: "Chats"), asOf: asOf)
        }
        .id("chats")
    }

    private func pin(_ chat: ConversationSummary, _ pinned: Bool) {
        Task { await actions.pin(chat, pinned, in: session.engine) }
    }

    private func archive(_ chat: ConversationSummary) {
        Task { await actions.archive(chat, in: session.engine) }
    }

    // MARK: More

    /// The Mac's places beside the projects (docs/design/iphone.md's drawing, "Further down"), each with what the engine
    /// says of it now. Their screens are later issues', which have no route yet: each opens the placeholder that says so.
    private var more: some View {
        let engine = session.engine
        let running = engine.backgroundCommands.count
        let archived = HomeLists.archivedCount(engine)
        return Section("More") {
            NavigationLink { FeaturePlaceholder(screen: "Templates", issue: 696) } label: {
                HomeMoreRow(title: "Templates", icon: "person.2") {
                    if loaded { Text("\(engine.agents.count)").monospacedDigit() }
                }
            }
            NavigationLink { FeaturePlaceholder(screen: "Schedules", issue: 697) } label: {
                HomeMoreRow(title: "Schedules", icon: "calendar.badge.clock") {
                    if !engine.schedules.isEmpty { Text("\(engine.schedules.count)").monospacedDigit() }
                }
            }
            NavigationLink { FeaturePlaceholder(screen: "Background commands", issue: 698) } label: {
                HomeMoreRow(title: "Background Commands", icon: "terminal") {
                    if running > 0 { Text("\(running) running").foregroundStyle(.tint) }
                }
            }
            NavigationLink { FeaturePlaceholder(screen: "Usage and limits", issue: 697) } label: {
                HomeMoreRow(title: "Usage and Limits", icon: "chart.bar") {
                    if engine.usage?.overBudget == true { Text("over budget").foregroundStyle(.red) }
                }
            }
            NavigationLink { FeaturePlaceholder(screen: "Archive", issue: 698) } label: {
                HomeMoreRow(title: "Archive", icon: "archivebox") {
                    if archived > 0 { Text("\(archived)").monospacedDigit() }
                }
            }
            NavigationLink { FeaturePlaceholder(screen: "Settings", issue: 697) } label: {
                HomeMoreRow(title: "Settings", icon: "gearshape") { EmptyView() }
            }
        }
        .id("more")
    }
}

#Preview("Projects") {
    NavigationStack { HomeView() }
        .environment(AppSession(connection: .connected(.relay)))
}
