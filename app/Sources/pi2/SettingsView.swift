import SwiftUI

struct SettingsView: View {
    let engine: EngineClient

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            ProvidersSettings(engine: engine)
                .tabItem { Label("Providers", systemImage: "key") }
            ToolsSettings(engine: engine)
                .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
            StorageSettings(engine: engine)
                .tabItem { Label("Storage", systemImage: "externaldrive") }
        }
        .frame(width: 660, height: 600)
    }
}

struct GeneralSettings: View {
    @AppStorage(Notifier.defaultsKey) private var notify = false
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
                if denied {
                    Text("macOS is not allowing notifications from pi². Turn them on in System Settings › Notifications.")
                        .font(.callout).foregroundStyle(.orange)
                }
            } footer: {
                Text("Approvals and questions are shown as notifications while pi² is in the background. The Dock icon always shows how many are waiting.").formFooter()
            }
            BackgroundSettings()
            UpdateSettings()
        }
        .formStyle(.grouped)
    }
}

/// How long the engine lives: with the app, after it quits, or from login.
struct BackgroundSettings: View {
    static let keepEngineKey = "keepEngineAfterQuit"
    @AppStorage(BackgroundSettings.keepEngineKey) private var keepEngine = false
    @State private var atLogin = EngineLoginItem.installed
    @State private var error: String?

    var body: some View {
        Section {
            Toggle("Keep agents running after I quit pi²", isOn: $keepEngine)
            // A closure, not the method itself: Swift 6.3 (Xcode 26) crashes turning a method into a binding's setter.
            Toggle("Start the engine when I log in", isOn: Binding(get: { atLogin }, set: { setLoginItem($0) }))
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
            let home = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("pi2").path
            do {
                try EngineLoginItem.install(node: node, main: main, home: home)
            } catch {
                self.error = "Could not install the login item: \(error.localizedDescription)"
            }
        } else {
            EngineLoginItem.remove()
        }
        atLogin = EngineLoginItem.installed
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
        }
        .formStyle(.grouped)
        .sheet(item: $keyTarget) { provider in
            KeySheet(engine: engine, provider: provider)
        }
        .sheet(item: $modelsTarget) { provider in
            ModelsSheet(engine: engine, provider: provider)
        }
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

    /// The sheet's own copy of the choice, so quick ticks build on each other without waiting for the engine.
    @State private var hidden: Set<String> = []

    private var models: [ModelInfo] {
        engine.allModels.filter { $0.provider == provider.id }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.name)
                        Text(model.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.bordered)
            .frame(height: 320)
            .overlay {
                if matches.isEmpty, filtering { ContentUnavailableView.search(text: query) }
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
        .frame(width: 480)
        .onAppear {
            hidden = Set(models.filter { $0.hidden == true }.map(\.id))
            searching = true
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
