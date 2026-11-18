import LoginItemKit
import SwiftUI

/// The tabs of the Settings window, by the names a development build can open it on with `PI2_SHOW=settings:<name>`
/// (docs/development.md). In the order they appear.
enum SettingsTab: String, CaseIterable {
    case general, chat, providers, tools, storage
}

/// The sections of those tabs, by the short names `PI2_SHOW=settings:<tab>#<name>` brings to the top of a tab.
enum SettingsSection: String {
    // General
    case appearance, notifications, background, updates
    // Chat
    case instructions, newChats = "new-chats", memory, agentNotes = "agent-notes"
    // Providers
    case subscriptions, endpoints, local, keys
    // Tools
    case servers, commits, priority
    // Storage
    case folder, backup
}

#if PI2_DEVELOPMENT
/// The Settings window as `PI2_SHOW` asked a development build for it: "settings", "settings:<tab>" or
/// "settings:<tab>#<section>". A tab it does not know is General, and a section the tab does not have leaves the tab
/// at its top.
struct SettingsLaunch {
    var tab = SettingsTab.general
    var section: SettingsSection?
    /// On Providers, `#models=<provider>` opens that provider's Models sheet, and `#add-model=<provider>/<id>` its sheet
    /// for adding a model by id, with the id typed and looked up: the provider and, when asked, the id.
    var modelsSheet: (provider: String, adding: String?)?
    /// On Providers, `#local=engine`, `#local=model` or `#local=configure:<model id>` opens that sheet of the section for
    /// models on this Mac, once it has what it needs.
    var localSheet: String?
    /// On Tools, `#variables=<server id>` opens that MCP server's Variables sheet.
    var variablesSheet: String?

    init?(_ value: String?) {
        guard let value, value == "settings" || value.hasPrefix("settings:") else { return nil }
        let asked = value.dropFirst("settings:".count).split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        if let name = asked.first, let tab = SettingsTab(rawValue: String(name)) { self.tab = tab }
        if asked.count > 1 {
            let part = String(asked[1])
            section = SettingsSection(rawValue: part)
            if part.hasPrefix("models=") {
                modelsSheet = (String(part.dropFirst("models=".count)), nil)
            } else if part.hasPrefix("local=") {
                section = .local
                localSheet = String(part.dropFirst("local=".count))
            } else if part.hasPrefix("add-model=") {
                let target = part.dropFirst("add-model=".count).split(separator: "/", maxSplits: 1)
                if let provider = target.first { modelsSheet = (String(provider), target.count > 1 ? String(target[1]) : "") }
            } else if part.hasPrefix("variables=") {
                variablesSheet = String(part.dropFirst("variables=".count))
            }
        }
    }

    /// The provider whose Models sheet was asked for, once.
    @MainActor private static var sheetShown = false
    @MainActor static func takeModelsSheet() -> String? {
        guard !sheetShown, let sheet = asked?.modelsSheet, asked?.tab == .providers else { return nil }
        sheetShown = true
        return sheet.provider
    }

    /// The sheet of the section for models on this Mac that was asked for, once.
    @MainActor private static var localShown = false
    @MainActor static func takeLocalSheet() -> String? {
        guard !localShown, let sheet = asked?.localSheet, asked?.tab == .providers else { return nil }
        localShown = true
        return sheet
    }

    /// The MCP server whose Variables sheet was asked for, once.
    @MainActor private static var variablesShown = false
    @MainActor static func takeVariablesSheet() -> String? {
        guard !variablesShown, let server = asked?.variablesSheet, asked?.tab == .tools else { return nil }
        variablesShown = true
        return server
    }

    /// The id to add to `provider` in its Models sheet, once: empty to open the form with none typed.
    @MainActor private static var addingShown = false
    @MainActor static func takeAdding(_ provider: String) -> String? {
        guard !addingShown, let sheet = asked?.modelsSheet, sheet.provider == provider, let adding = sheet.adding else { return nil }
        addingShown = true
        return adding
    }

    @MainActor static let asked = SettingsLaunch(ProcessInfo.processInfo.environment["PI2_SHOW"])
    /// Whether the window is still to be opened, and whether the tab is still to be scrolled: each happens once, so
    /// opening Settings again later, or coming back to the tab, shows it as usual.
    @MainActor private static var toOpen = asked != nil
    @MainActor private static var toScroll = asked?.section != nil

    /// True the first time it is asked, when `PI2_SHOW` asked for Settings.
    @MainActor static func takeWindow() -> Bool {
        defer { toOpen = false }
        return toOpen
    }

    /// Brings the section asked for to the top of `tab`'s form, if `tab` is the one asked for. Parts of a tab fill in
    /// after it first appears (the providers, the MCP servers), which moves the sections below them, so it scrolls
    /// again while the tab settles.
    @MainActor static func scroll(_ tab: SettingsTab, with proxy: ScrollViewProxy) async {
        guard toScroll, let asked, asked.tab == tab, let section = asked.section else { return }
        toScroll = false
        for delay in [100, 400, 1000, 2000] {
            try? await Task.sleep(for: .milliseconds(delay))
            proxy.scrollTo(section, anchor: .top)
        }
    }
}
#endif

extension View {
    /// For the form of a Settings tab, whose sections carry a `SettingsSection` as their id: lets a development build
    /// open the tab with one of them at the top.
    func settingsPage(_ tab: SettingsTab) -> some View {
        #if PI2_DEVELOPMENT
        ScrollViewReader { proxy in
            task { await SettingsLaunch.scroll(tab, with: proxy) }
        }
        #else
        self
        #endif
    }
}

struct SettingsView: View {
    let engine: EngineClient
    @State private var tab: SettingsTab = {
        #if PI2_DEVELOPMENT
        if let asked = SettingsLaunch.asked { return asked.tab }
        #endif
        return .general
    }()

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings(home: engine.dataFolder.path)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            ChatSettingsView(engine: engine)
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                .tag(SettingsTab.chat)
            ProvidersSettings(engine: engine)
                .tabItem { Label("Providers", systemImage: "key") }
                .tag(SettingsTab.providers)
            ToolsSettings(engine: engine)
                .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
                .tag(SettingsTab.tools)
            StorageSettings(engine: engine)
                .tabItem { Label("Storage", systemImage: "externaldrive") }
                .tag(SettingsTab.storage)
        }
        .frame(width: 660, height: 600)
    }
}

struct GeneralSettings: View {
    /// This copy's data folder.
    let home: String
    @AppStorage(Notifier.defaultsKey) private var notify = false
    @AppStorage(Notifier.limitsKey) private var notifyLimits = true
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.dark.rawValue
    @State private var denied = false

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .onChange(of: appearance) { _, value in AppAppearance.apply(AppAppearance(rawValue: value) ?? .dark) }
            } footer: {
                Text("pi² is designed dark first. Light follows the same palette.").formFooter()
            }
            .id(SettingsSection.appearance)
            Section {
                Toggle("Notify me when an agent needs me", isOn: $notify)
                    .onChange(of: notify) { _, on in
                        guard on else { return }
                        Task {
                            if await !Notifier.shared.requestPermission() {
                                notify = false
                                denied = true
                            }
                        }
                    }
                Toggle("Notify me when a subscription’s limit is reached, and when work carries on", isOn: $notifyLimits)
                    .onChange(of: notifyLimits) { _, on in
                        guard on else { return }
                        Task {
                            if await !Notifier.shared.requestPermission() {
                                notifyLimits = false
                                denied = true
                            }
                        }
                    }
                if denied {
                    Text("macOS is not allowing notifications from pi². Turn them on in System Settings › Notifications.")
                        .font(.callout).foregroundStyle(.orange)
                }
            } footer: {
                Text("Approvals and questions are shown as notifications while pi² is in the background. The Dock icon always shows how many are waiting. A run a provider refuses for its limit waits and carries on by itself; the Inbox says so either way, and the second switch adds a notification once when the limit is reached and once when work carries on.").formFooter()
            }
            .id(SettingsSection.notifications)
            BackgroundSettings(home: home)
                .id(SettingsSection.background)
            UpdateSettings()
                .id(SettingsSection.updates)
        }
        .formStyle(.grouped)
        .settingsPage(.general)
    }
}

/// How long the engine lives: with the app, after it quits, or from login.
struct BackgroundSettings: View {
    static let keepEngineKey = "keepEngineAfterQuit"
    @AppStorage(BackgroundSettings.keepEngineKey) private var keepEngine = false
    /// This copy's data folder. Only the copy whose data folder the login item serves may change it.
    let home: String
    @State private var loginItem = EngineLoginItem.installedItem
    @State private var error: String?

    var body: some View {
        Section {
            Toggle("Keep agents running after I quit pi²", isOn: $keepEngine)
            let atLogin = EngineLoginItem.switchState(loginItem, home: home)
            // A closure, not the method itself: Swift 6.3 (Xcode 26) crashes turning a method into a binding's setter.
            Toggle("Start the engine when I log in", isOn: Binding(get: { atLogin == .on }, set: { setLoginItem($0) }))
                .disabled(atLogin.isUnavailable)
            if case .unavailable(let why) = atLogin { Text(why).font(.callout).foregroundStyle(.secondary) }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
        } header: {
            Text("In the background")
        } footer: {
            Text("Closing the window always leaves pi² in the menu bar with agents running. These settings cover quitting the app and restarting the Mac, so schedules and long runs carry on.\(EngineClient.isSelfContained ? " If you move the app or it updates, the engine and the login item follow it the next time pi² opens." : " This development build runs the engine from its source folder, so that folder must stay where it is.")").formFooter()
        }
    }

    private func setLoginItem(_ on: Bool) {
        error = nil
        if on {
            guard let (node, main) = EngineClient.enginePaths else {
                error = "This build does not know where its engine is."
                return
            }
            do {
                try EngineLoginItem.install(node: node, main: main, home: home)
            } catch {
                self.error = "Could not install the login item: \(error.localizedDescription)"
            }
        } else {
            do {
                try EngineLoginItem.remove(home: home)
            } catch {
                self.error = "Could not remove the login item: \(error.localizedDescription)"
            }
        }
        loginItem = EngineLoginItem.installedItem
    }
}

struct ProvidersSettings: View {
    @Bindable var engine: EngineClient
    @State private var search = ""
    @State private var keyTarget: ProviderInfo?
    @State private var addingEndpoint = false
    @State private var editingEndpoint: ProviderInfo?
    @State private var modelsTarget: ProviderInfo?

    /// How many of a provider's models the pickers offer, and the button that changes it.
    @ViewBuilder
    private func modelsButton(_ provider: ProviderInfo) -> some View {
        let all = engine.allModels.filter { $0.provider == provider.id }
        if !all.isEmpty {
            let shown = all.filter { $0.hidden != true }.count
            Button(shown == all.count ? "Models…" : "Models (\(shown) of \(all.count))…") { modelsTarget = provider }
                .help("Choose which of \(provider.name)'s models appear in the model menus")
        }
    }

    private var subscriptions: [ProviderInfo] {
        engine.providers.filter { $0.oauth?.subscription == true }
    }
    private var keyProviders: [ProviderInfo] {
        engine.providers
            .filter { $0.keyAuth && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
            .sorted { ($0.status != nil ? 0 : 1, $0.name.lowercased()) < ($1.status != nil ? 0 : 1, $1.name.lowercased()) }
    }
    private var endpoints: [ProviderInfo] { engine.providers.filter { $0.kind == "custom" } }

    var body: some View {
        Form {
            Section {
                ForEach(subscriptions) { provider in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.oauth?.name ?? provider.name)
                            Text(provider.status?.type == "oauth" ? "Signed in · \(provider.modelCount) models" : "Not signed in")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if provider.status?.type == "oauth" {
                            modelsButton(provider)
                            Button("Sign Out") { engine.perform("providers.logout", ["id": provider.id]) }
                        } else {
                            Button("Sign In…") { engine.startSignIn(provider) }
                        }
                    }
                }
            } header: {
                Text("Subscriptions")
            } footer: {
                Text("Sign-in uses your existing plan. Each provider decides whether its subscription may be used from other apps; check their terms.").formFooter()
            }
            .id(SettingsSection.subscriptions)

            Section {
                ForEach(endpoints) { provider in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.name)
                            Text("\(provider.endpoint?.baseUrl ?? "") · \(provider.modelCount) model\(provider.modelCount == 1 ? "" : "s")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        modelsButton(provider)
                        Button("Edit…") { editingEndpoint = provider }
                            .help("Change this endpoint's address or models, or say which of its models can see pictures")
                        Button("Remove", role: .destructive) { engine.perform("endpoints.remove", ["id": provider.id]) }
                    }
                }
                Button("Add Endpoint…") { addingEndpoint = true }
            } header: {
                Text("Hosted and local endpoints")
            } footer: {
                Text("Any server that speaks the OpenAI or Anthropic API: Ollama, LM Studio, vLLM, llama.cpp, or a gateway you run.").formFooter()
            }
            .id(SettingsSection.endpoints)

            LocalModelsSection(engine: engine)
                .id(SettingsSection.local)

            Section("API keys") {
                TextField("Search providers", text: $search)
                ForEach(keyProviders) { provider in
                    HStack {
                        Circle().fill(provider.status != nil ? Color.green : Color.secondary.opacity(0.35)).frame(width: 8, height: 8)
                        Text(provider.name)
                        Spacer()
                        Text(provider.statusText).font(.caption).foregroundStyle(.secondary)
                        if provider.status != nil { modelsButton(provider) }
                        if provider.status?.source == "stored credential" {
                            Button("Remove") { engine.perform("providers.logout", ["id": provider.id]) }
                        } else if provider.status == nil {
                            Button("Add Key…") { keyTarget = provider }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .id(SettingsSection.keys)
        }
        .formStyle(.grouped)
        .settingsPage(.providers)
        .sheet(item: $keyTarget) { provider in
            KeySheet(engine: engine, provider: provider)
        }
        .sheet(item: $modelsTarget) { provider in
            ModelsSheet(engine: engine, provider: provider)
        }
        #if PI2_DEVELOPMENT
        .task {
            // The providers arrive a moment after the tab appears.
            guard let wanted = SettingsLaunch.takeModelsSheet() else { return }
            for _ in 0..<100 {
                if let provider = engine.providers.first(where: { $0.id == wanted }), engine.allModels.contains(where: { $0.provider == provider.id }) {
                    modelsTarget = provider
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        #endif
        .sheet(isPresented: $addingEndpoint) {
            EndpointSheet(engine: engine)
        }
        .sheet(item: $editingEndpoint) { provider in
            EndpointSheet(engine: engine, existing: provider.endpoint)
        }
        .sheet(isPresented: Binding(get: { engine.signIn != nil }, set: { if !$0 { engine.cancelSignIn() } })) {
            SignInSheet(engine: engine)
        }
    }
}

/// Which of one provider's models the model menus offer.
struct ModelsSheet: View {
    let engine: EngineClient
    let provider: ProviderInfo
    @State private var error: String?
    @State private var query = ""
    @FocusState private var searching: Bool
    @Environment(\.dismiss) private var dismiss
    /// A model to add by its id (an empty id) or one added by hand to change.
    @State private var adding: AddModelTarget?
    @State private var removing: ModelInfo?
    /// What the provider said when asked for its models, shown in the list's place until Back.
    @State private var listing: ProviderListing?
    @State private var asking = false

    /// The sheet's own copy of the choice, so quick ticks build on each other without waiting for the engine.
    @State private var hidden: Set<String> = []

    /// By name, those added by hand first, where they can be found again.
    private var models: [ModelInfo] {
        engine.allModels.filter { $0.provider == provider.id }.sorted {
            ($0.addedByHand == true) != ($1.addedByHand == true) ? $0.addedByHand == true : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    private var shown: Int { models.filter { !hidden.contains($0.id) }.count }
    private var filtering: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The models the search leaves: every word typed has to be in the model's name or its id.
    private var matches: [ModelInfo] {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map { String($0) }
        guard !words.isEmpty else { return models }
        return models.filter { model in
            words.allSatisfy { word in
                model.name.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                    || model.id.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    var body: some View {
        // Adding a model takes the sheet's place rather than opening a sheet over it, which SwiftUI does not always show.
        Group {
            if let target = adding {
                AddModelForm(engine: engine, provider: provider, editing: target.id.isEmpty ? nil : target.id, typed: target.typed) { adding = nil }
            } else if let listing {
                ListingView(engine: engine, provider: provider, listing: listing, add: { adding = AddModelTarget(id: "", typed: $0) }, back: { self.listing = nil })
            } else {
                list
            }
        }
        #if PI2_DEVELOPMENT
        .task {
            if let typed = SettingsLaunch.takeAdding(provider.id) { adding = AddModelTarget(id: "", typed: typed) }
        }
        #endif
        .confirmationDialog(
            "Remove \(removing?.name ?? "this model")?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { model in
            Button("Remove", role: .destructive) { remove(model) }
        } message: { model in
            Text(removalNote(model))
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(provider.name) models").font(.headline)
            Text("Ticked models appear in the model menus. A hidden model that a conversation or agent already uses keeps working.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                TextField("Search", text: $query, prompt: Text("Search by name or id"))
                    .textFieldStyle(.roundedBorder)
                    .focused($searching)
                    .accessibilityLabel("Search models")
                if !query.isEmpty {
                    Button("Clear Search", systemImage: "xmark.circle.fill") {
                        query = ""
                        searching = true
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Clear the search")
                }
            }
            HStack {
                // With a search typed, the two buttons act on what it found and leave the rest as it is.
                Button(filtering ? "Select Matches" : "Select All") { setShown(true) }
                    .disabled(matches.allSatisfy { !hidden.contains($0.id) })
                    .help(filtering ? "Tick every model the search found" : "Tick every model")
                Button(filtering ? "Deselect Matches" : "Deselect All") { setShown(false) }
                    .disabled(matches.allSatisfy { hidden.contains($0.id) })
                    .help(filtering ? "Untick every model the search found" : "Untick every model, to then pick the few you want")
                Spacer()
                Button("Newest Only") { apply(["id": provider.id, "newest": true]) }
                    .help("Keep the newest version of each model family, such as one Opus, one Sonnet and one Haiku")
            }
            List(matches) { model in
                Toggle(isOn: Binding(
                    get: { !hidden.contains(model.id) },
                    set: { show in
                        if show { hidden.remove(model.id) } else { hidden.insert(model.id) }
                        apply(["id": provider.id, "hidden": hidden.sorted()])
                    }
                )) {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.name)
                            Text(model.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        if model.addedByHand == true {
                            Spacer()
                            Tag("Added by hand", .acc)
                                .help("Added by its id. Its settings were taken from a model pi² knows; its price is not known.")
                            Button("Edit…") { adding = AddModelTarget(id: model.id) }
                                .help("Change what pi² assumes about this model")
                            Button("Remove") { removing = model }
                                .help("Remove this model from pi²")
                        }
                    }
                }
            }
            .listStyle(.bordered)
            .frame(height: 320)
            .overlay {
                if matches.isEmpty, filtering { ContentUnavailableView.search(text: query) }
            }
            if provider.kind == "builtin" {
                HStack(alignment: .firstTextBaseline) {
                    Button("Add a Model by ID…") { adding = AddModelTarget(id: "") }
                        .help("Add a model that pi² does not list yet, such as one released today, by the id \(provider.name) gives it")
                    Text("For a model newer than pi²'s list. It uses this \(provider.status?.type == "oauth" ? "sign-in" : "key").")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                askRow
            }
            if shown == 0, !models.isEmpty {
                Text("None are ticked, so \(provider.name) has no models in the model menus.")
                    .font(.callout).foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Text(filtering ? "\(matches.count) found · \(shown) of \(models.count) showing" : "\(shown) of \(models.count) showing")
                    .font(.callout).foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            hidden = Set(models.filter { $0.hidden == true }.map(\.id))
            searching = true
        }
    }

    /// Asks the provider which models this key or sign-in can use, or says why it cannot be asked.
    @ViewBuilder
    private var askRow: some View {
        let credential = provider.status?.type == "oauth" ? "sign-in" : "key"
        if let ask = provider.ask {
            if ask.can {
                HStack(alignment: .firstTextBaseline) {
                    Button(asking ? "Asking \(provider.name)…" : "Ask \(provider.name)…") { askProvider() }
                        .disabled(asking)
                        .help("Ask \(provider.name) which models this \(credential) can use, and offer the ones pi² does not list")
                    Text(ask.url.map { "Asks \(URL(string: $0)?.host() ?? $0) which models this \(credential) can use." } ?? "Gets \(provider.name)'s list of models again.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if let why = ask.why {
                Text("\(why) Add a model by its id instead.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func askProvider() {
        asking = true
        error = nil
        Task {
            defer { asking = false }
            do {
                let result = try await engine.call("providers.ask", ["id": provider.id])
                listing = try JSONDecoder().decode(ProviderListing.self, from: JSONEncoder().encode(result))
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// What removing a model added by hand does to what uses it.
    private func removalNote(_ model: ModelInfo) -> String {
        let agents = engine.agents.filter { $0.model == model.ref }.map(\.name)
        let users = agents.isEmpty ? "" : " \(ListFormatter.localizedString(byJoining: agents)) \(agents.count == 1 ? "uses" : "use") it, and will start new conversations on the default model instead."
        return "A conversation that uses it stops with a message at its next turn, until another model is chosen.\(users) You can add it again later."
    }

    private func remove(_ model: ModelInfo) {
        Task {
            do {
                try await engine.call("providers.removeModel", ["provider": provider.id, "id": model.id])
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Ticks or unticks every model the search leaves (all of them when nothing is typed) in one step.
    private func setShown(_ show: Bool) {
        let ids = matches.map(\.id)
        if show { hidden.subtract(ids) } else { hidden.formUnion(ids) }
        apply(["id": provider.id, "hidden": hidden.sorted()])
    }

    private func apply(_ params: [String: Any]) {
        Task {
            do {
                let result = try await engine.call("providers.setHiddenModels", params)
                // "Newest only" is worked out by the engine; take its answer.
                if params["newest"] != nil, let chosen = result["hidden"]?.arrayValue { hidden = Set(chosen.compactMap(\.stringValue)) }
                error = nil
            } catch {
                self.error = error.localizedDescription
                hidden = Set(models.filter { $0.hidden == true }.map(\.id))
            }
        }
    }
}

/// The models a provider listed when asked, those pi² does not list first, each to add as by its id.
struct ListingView: View {
    let engine: EngineClient
    let provider: ProviderInfo
    let listing: ProviderListing
    let add: (String) -> Void
    let back: () -> Void

    private func added(_ id: String) -> Bool { engine.allModels.contains { $0.provider == provider.id && $0.id == id } }
    private var new: [ProviderListing.Listed] { listing.models.filter { !$0.known } }

    private var summary: String {
        let credential = provider.status?.type == "oauth" ? "sign-in" : "key"
        guard let asked = listing.asked else {
            return "\(listing.providerName)'s list of models was fetched again: pi² now lists \(listing.catalogCount)."
        }
        let host = URL(string: asked)?.host() ?? asked
        let count = listing.models.count
        let lists = "Asked \(host) with your \(credential): it lists \(count) model\(count == 1 ? "" : "s") for chat"
        if new.isEmpty { return "\(lists), and pi² knows every one." }
        return "\(lists), \(new.count) of them not in pi²'s list. Add the ones you want: pi² takes what \(listing.providerName) says of each, and the rest from a model it knows."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Models \(listing.providerName) offers").font(.headline)
            Text(summary)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !new.isEmpty {
                List(new) { model in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.name)
                            Text(model.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if added(model.id) {
                            Tag("Added by hand", .acc)
                        } else {
                            Button("Add…") { add(model.id) }
                                .help("Add \(model.id), checking what pi² takes for it first")
                        }
                    }
                }
                .listStyle(.bordered)
                .frame(height: 300)
            }
            HStack {
                Spacer()
                Button("Back") { back() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

struct AddModelTarget: Identifiable {
    /// The id of a model added by hand, to change it; empty to add a new one.
    let id: String
    /// For a new one, an id already typed and looked up.
    var typed: String?
}

/// Adds a model by its id to a built-in provider, or changes one added so: pi² proposes its settings from a model of
/// the provider it knows, shows them, and the person changes what they know better. Shown in the Models sheet's place.
struct AddModelForm: View {
    let engine: EngineClient
    let provider: ProviderInfo
    /// The model added by hand being changed; nil when adding one.
    let editing: String?
    /// For a new one, an id already typed, to look up at once.
    var typed: String?
    /// Back to the list of models, when added or cancelled.
    let close: () -> Void
    @State private var id = ""
    @State private var draft: ModelDraft?
    @State private var contextText = ""
    @State private var maxText = ""
    @State private var thinks = false
    @State private var levels: Set<String> = []
    @State private var error: String?
    @State private var working = false
    @FocusState private var typingId: Bool

    /// pi-ai's thinking levels, in order.
    private static let allLevels = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]
    private static let apiNames = [
        "openai-responses": "OpenAI Responses", "openai-codex-responses": "OpenAI Codex Responses", "openai-completions": "OpenAI chat completions",
        "anthropic-messages": "Anthropic Messages", "google-generative-ai": "Google Gemini", "google-vertex": "Google Vertex",
        "mistral-conversations": "Mistral", "bedrock-converse-stream": "Amazon Bedrock", "azure-openai-responses": "Azure OpenAI Responses",
    ]
    private func apiName(_ api: String) -> String { Self.apiNames[api] ?? api }

    private var trimmedId: String { id.trimmingCharacters(in: .whitespaces) }
    /// The draft is for what is typed, not an id typed before it.
    private var current: ModelDraft? { draft?.id == trimmedId ? draft : nil }
    private var contextWindow: Int? { Int(contextText.filter { $0 != "," && $0 != " " }) }
    private var maxTokens: Int? { Int(maxText.filter { $0 != "," && $0 != " " }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    HStack {
                        TextField("Model ID", text: $id, prompt: Text("gpt-6.2-sol"))
                            .focused($typingId)
                            .onSubmit { lookUp() }
                            .disabled(editing != nil)
                        if editing == nil {
                            Button("Look Up") { lookUp() }
                                .disabled(trimmedId.isEmpty || working || current != nil)
                        }
                    }
                } header: {
                    Text(editing == nil ? "Add a model to \(provider.name)" : "Change a model added to \(provider.name)")
                } footer: {
                    Text("The id as \(provider.name) names it, as in its announcement or documentation, such as gpt-6.2-sol rather than GPT 6.2 Sol. pi² does not ask \(provider.name) about it until a conversation uses it.").formFooter()
                }
                if let draft = current {
                    Section {
                        Picker("Based on", selection: Binding(get: { draft.basedOn }, set: { redraft(["basedOn": $0]) })) {
                            ForEach(draft.templates) { Text("\($0.name) (\($0.id))").tag($0.id) }
                        }
                        if draft.apis.count > 1 {
                            Picker("API", selection: Binding(get: { draft.api }, set: { redraft(["api": $0]) })) {
                                ForEach(draft.apis, id: \.self) { Text(apiName($0)).tag($0) }
                            }
                        } else {
                            LabeledContent("API", value: apiName(draft.api))
                        }
                        TextField("Name", text: Binding(get: { self.draft?.name ?? "" }, set: { self.draft?.name = $0 }))
                        TextField("Context size, in tokens", text: $contextText)
                        TextField("Longest answer, in tokens", text: $maxText)
                        Toggle("Can see pictures", isOn: Binding(get: { self.draft?.vision ?? false }, set: { self.draft?.vision = $0 }))
                        Toggle("Thinks before answering", isOn: Binding(get: { thinks }, set: { on in
                            thinks = on
                            // Switched on with no level to think at: the usual three.
                            if on, levels.allSatisfy({ $0 == "off" }) { levels.formUnion(["low", "medium", "high"]) }
                        }))
                        if thinks {
                            LabeledContent("Thinking levels") {
                                HStack(spacing: 4) {
                                    ForEach(Self.allLevels, id: \.self) { level in
                                        Toggle(level.capitalized, isOn: Binding(
                                            get: { levels.contains(level) },
                                            set: { if $0 { levels.insert(level) } else { levels.remove(level) } }
                                        ))
                                        .toggleStyle(.button)
                                        .controlSize(.small)
                                    }
                                }
                            }
                        }
                    } header: {
                        Text(takenFrom(draft))
                    } footer: {
                        if !draft.editing, draft.told?.contains("thinking levels") != true {
                            Text("Thinking levels are copied from \(draft.basedOnName) and may not all work on this model.").formFooter()
                        }
                        Text("pi² does not know this model's price: Usage counts its tokens and shows no cost. It uses your \(provider.name) \(provider.status?.type == "oauth" ? "sign-in" : "key"). If \(provider.name) does not offer the model to it, a conversation that uses it stops and says so. Once pi²'s own list has the model, that entry takes this one's place.").formFooter()
                    }
                }
            }
            .formStyle(.grouped)

            if let error {
                Text(error).font(.callout).foregroundStyle(.red).padding(.horizontal, 20).padding(.bottom, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { close() }.keyboardShortcut(.cancelAction)
                Button(editing == nil ? "Add Model" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(current == nil || contextWindow == nil || maxTokens == nil || working)
            }
            .padding(20)
        }
        .frame(width: 560, height: 560)
        .onAppear {
            if let start = editing ?? typed.flatMap({ $0.isEmpty ? nil : $0 }) {
                id = start
                lookUp()
            } else {
                typingId = true
            }
        }
    }

    private func takenFrom(_ draft: ModelDraft) -> String {
        if let told = draft.told, !told.isEmpty {
            let said = ListFormatter.localizedString(byJoining: told)
            return "\(said.prefix(1).uppercased() + said.dropFirst()) as \(draft.providerName) says; the rest taken from \(draft.basedOnName). Change anything you know is different."
        }
        return switch draft.match {
        case "family": "Taken from \(draft.basedOnName), the newest \(draft.providerName) model of the same family. Change anything you know is different."
        case "nearest": "pi² knows no \(draft.providerName) model of this family. Taken from \(draft.basedOnName), the closest: check these."
        default: "Taken from \(draft.basedOnName)."
        }
    }

    private func lookUp() {
        guard !trimmedId.isEmpty, current == nil else { return }
        redraft([:])
    }

    /// Asks the engine for its proposal for the id typed, based on another model or speaking another API if asked.
    private func redraft(_ choice: [String: String]) {
        working = true
        error = nil
        var params: [String: Any] = ["provider": provider.id, "id": trimmedId]
        for (key, value) in choice { params[key] = value }
        let name = draft?.name
        Task {
            defer { working = false }
            do {
                let result = try await engine.call("providers.draftModel", params)
                var proposed = try JSONDecoder().decode(ModelDraft.self, from: JSONEncoder().encode(result))
                // A name typed already is kept when only what it is based on changes.
                if !choice.isEmpty, let name, draft?.id == proposed.id { proposed.name = name }
                draft = proposed
                contextText = String(proposed.contextWindow)
                maxText = String(proposed.maxTokens)
                levels = Set(proposed.thinkingLevels)
                thinks = !proposed.thinkingLevels.filter { $0 != "off" }.isEmpty
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func save() {
        guard let draft = current, let contextWindow, let maxTokens else { return }
        working = true
        error = nil
        let chosen = thinks ? Self.allLevels.filter { levels.contains($0) } : []
        Task {
            defer { working = false }
            do {
                try await engine.call("providers.addModel", [
                    "provider": provider.id, "id": draft.id, "name": draft.name, "basedOn": draft.basedOn,
                    "contextWindow": contextWindow, "maxTokens": maxTokens, "vision": draft.vision, "thinkingLevels": chosen,
                ])
                close()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct KeySheet: View {
    let engine: EngineClient
    let provider: ProviderInfo
    @State private var key = ""
    @State private var error: String?
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(provider.name) API key").font(.headline)
            SecureField("Paste the key", text: $key)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            Text("Stored in your macOS Keychain. It is never written to pi²'s own files.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || saving)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func save() {
        saving = true
        Task {
            do {
                try await engine.call("providers.setKey", ["id": provider.id, "key": key])
                dismiss()
            } catch {
                self.error = error.localizedDescription
                saving = false
            }
        }
    }
}

struct EndpointSheet: View {
    let engine: EngineClient
    /// The endpoint being changed; nil when adding one.
    var existing: EndpointConfig?
    @State private var name = ""
    @State private var baseUrl = ""
    @State private var api = "openai-completions"
    @State private var key = ""
    @State private var found: [String] = []
    @State private var chosen: Set<String> = []
    /// The chosen models the person says can see pictures. A server cannot be asked, so it is theirs to say.
    @State private var vision: Set<String> = []
    @State private var manualModel = ""
    @State private var error: String?
    @State private var working = false
    @State private var fetching = false
    @Environment(\.dismiss) private var dismiss

    private let presets = [
        ("Ollama", "http://localhost:11434/v1"),
        ("LM Studio", "http://localhost:1234/v1"),
        ("llama.cpp", "http://localhost:8080/v1"),
        ("vLLM", "http://localhost:8000/v1"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    Picker("Start from", selection: Binding(get: { "" }, set: { choice in
                        if let preset = presets.first(where: { $0.0 == choice }) {
                            name = preset.0
                            baseUrl = preset.1
                            api = "openai-completions"
                        }
                    })) {
                        Text("Custom").tag("")
                        ForEach(presets, id: \.0) { Text($0.0).tag($0.0) }
                    }
                    TextField("Name", text: $name, prompt: Text("Home GPU box"))
                    TextField("Base URL", text: $baseUrl, prompt: Text("http://localhost:11434/v1"))
                    Picker("API style", selection: $api) {
                        Text("OpenAI chat completions").tag("openai-completions")
                        Text("OpenAI responses").tag("openai-responses")
                        Text("Anthropic messages").tag("anthropic-messages")
                    }
                    SecureField("API key", text: $key, prompt: Text(existing == nil ? "Optional" : "Leave empty to keep the one saved"))
                }
                Section("Models") {
                    ForEach(found, id: \.self) { model in
                        Toggle(model, isOn: Binding(
                            get: { chosen.contains(model) },
                            set: { if $0 { chosen.insert(model) } else { chosen.remove(model) } }
                        ))
                    }
                    HStack {
                        TextField("Add a model by ID", text: $manualModel)
                            .onSubmit(addManual)
                        Button("Add") { addManual() }.disabled(manualModel.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Button(fetching ? "Asking the server…" : "Fetch Models From Server") { fetch() }
                        .disabled(baseUrl.isEmpty || working)
                }
                if !chosen.isEmpty {
                    Section {
                        ForEach(found.filter { chosen.contains($0) }, id: \.self) { model in
                            Toggle(model, isOn: Binding(
                                get: { vision.contains(model) },
                                set: { sees in if sees { vision.insert(model) } else { vision.remove(model) } }
                            ))
                        }
                    } header: {
                        Text("Can see pictures")
                    } footer: {
                        Text("Switch on the models that take pictures, such as LLaVA, Llama Vision or Qwen-VL. Pictures you attach and screenshots from computer use are sent only to those; pi² cannot ask the server which they are. A model that cannot see pictures, switched on here, will answer with an error or ignore them.").formFooter()
                    }
                }
            }
            .formStyle(.grouped)

            if let error {
                Text(error).font(.callout).foregroundStyle(.red).padding(.horizontal, 20).padding(.bottom, 8)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Add Endpoint" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty || baseUrl.isEmpty || chosen.isEmpty || working)
            }
            .padding(20)
        }
        .frame(width: 520, height: 600)
        .onAppear {
            guard let existing else { return }
            name = existing.name
            baseUrl = existing.baseUrl
            api = existing.api
            found = existing.models.map(\.id)
            chosen = Set(found)
            vision = Set(existing.models.filter { $0.vision == true }.map(\.id))
        }
    }

    private func addManual() {
        let model = manualModel.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else { return }
        if !found.contains(model) { found.append(model) }
        chosen.insert(model)
        manualModel = ""
    }

    private func fetch() {
        working = true
        fetching = true
        error = nil
        Task {
            defer {
                working = false
                fetching = false
            }
            do {
                let result = try await engine.call("endpoints.probe", ["baseUrl": baseUrl, "key": key])
                let models = (result["models"]?.arrayValue ?? []).compactMap(\.stringValue)
                for model in models where !found.contains(model) { found.append(model) }
                if chosen.isEmpty { chosen = Set(models) }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func save() {
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                // What an endpoint already says about a model (its name, its context size) is kept when it is saved again.
                let models = found.filter { chosen.contains($0) }.map { id in
                    var model = existing?.models.first { $0.id == id } ?? EndpointModel(id: id)
                    model.vision = vision.contains(id)
                    return model.payload
                }
                var params: [String: Any] = ["name": name, "baseUrl": baseUrl, "api": api, "models": models]
                if let existing { params["id"] = existing.id }
                if !key.isEmpty { params["key"] = key }
                try await engine.call("endpoints.save", params)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct SignInSheet: View {
    @Bindable var engine: EngineClient
    @State private var answer = ""

    var body: some View {
        if let flow = engine.signIn {
            VStack(alignment: .leading, spacing: 14) {
                Text("Sign in to \(flow.providerName)").font(.headline)
                ForEach(Array(flow.messages.enumerated()), id: \.offset) { _, message in
                    Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let code = flow.userCode {
                    HStack {
                        Text("Enter this code:")
                        Text(code).font(.system(.title3, design: .monospaced).weight(.semibold)).textSelection(.enabled)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code, forType: .string)
                        }
                    }
                }
                if let url = flow.openURL.flatMap(URL.init(string:)) {
                    HStack {
                        Text(flow.userCode == nil ? "Your browser was opened to finish signing in." : "Then approve it in your browser.")
                            .font(.callout)
                        Button(flow.userCode == nil ? "Open Again" : "Open Browser") { NSWorkspace.shared.open(url) }
                    }
                }
                if let prompt = flow.prompt {
                    Divider()
                    Text(prompt.message).font(.callout)
                    if prompt.type == "select", let options = prompt.options {
                        ForEach(options) { option in
                            Button {
                                engine.answerSignInPrompt(option.id)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(option.label)
                                    if let description = option.description { Text(description).font(.caption).foregroundStyle(.secondary) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    } else {
                        HStack {
                            if prompt.type == "secret" {
                                SecureField(prompt.placeholder ?? "", text: $answer).onSubmit(submitAnswer)
                            } else {
                                TextField(prompt.placeholder ?? "", text: $answer).onSubmit(submitAnswer)
                            }
                            Button("Continue") { submitAnswer() }.disabled(answer.isEmpty)
                        }
                        .textFieldStyle(.roundedBorder)
                    }
                } else if !flow.finished {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Waiting…").font(.callout).foregroundStyle(.secondary)
                    }
                }
                if let error = flow.error {
                    Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
                HStack {
                    Spacer()
                    Button(flow.finished ? "Close" : "Cancel", role: .cancel) { engine.cancelSignIn() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(20)
            .frame(width: 460)
        }
    }

    private func submitAnswer() {
        guard !answer.isEmpty else { return }
        engine.answerSignInPrompt(answer)
        answer = ""
    }
}
