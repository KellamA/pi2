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
    @State private var denied = false

    var body: some View {
        Form {
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
                Text("Approvals and questions are shown as notifications while pi² is in the background. The Dock icon always shows how many are waiting.")
            }
            BackgroundSettings()
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
            Toggle("Start the engine when I log in", isOn: Binding(get: { atLogin }, set: setLoginItem))
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
        } header: {
            Text("In the background")
        } footer: {
            Text("Closing the window always leaves pi² in the menu bar with agents running. These settings cover quitting the app and restarting the Mac, so schedules and long runs carry on.\(EngineClient.isSelfContained ? " The login item points at this copy of the app; turn it off and on again after moving the app." : " This development build runs the engine from its source folder, so that folder must stay where it is.")")
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
                            Button("Sign Out") { engine.perform("providers.logout", ["id": provider.id]) }
                        } else {
                            Button("Sign In…") { engine.startSignIn(provider) }
                        }
                    }
                }
            } header: {
                Text("Subscriptions")
            } footer: {
                Text("Sign-in uses your existing plan. Each provider decides whether its subscription may be used from other apps; check their terms.")
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
                        Button("Remove", role: .destructive) { engine.perform("endpoints.remove", ["id": provider.id]) }
                    }
                }
                Button("Add Endpoint…") { addingEndpoint = true }
            } header: {
                Text("Hosted and local endpoints")
            } footer: {
                Text("Any server that speaks the OpenAI or Anthropic API: Ollama, LM Studio, vLLM, llama.cpp, or a gateway you run.")
            }

            Section("API keys") {
                TextField("Search providers", text: $search)
                ForEach(keyProviders) { provider in
                    HStack {
                        Circle().fill(provider.status != nil ? Color.green : Color.secondary.opacity(0.35)).frame(width: 8, height: 8)
                        Text(provider.name)
                        Spacer()
                        Text(provider.statusText).font(.caption).foregroundStyle(.secondary)
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
        .sheet(isPresented: $addingEndpoint) {
            EndpointSheet(engine: engine)
        }
        .sheet(isPresented: Binding(get: { engine.signIn != nil }, set: { if !$0 { engine.cancelSignIn() } })) {
            SignInSheet(engine: engine)
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
    @State private var name = ""
    @State private var baseUrl = ""
    @State private var api = "openai-completions"
    @State private var key = ""
    @State private var found: [String] = []
    @State private var chosen: Set<String> = []
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
                    SecureField("API key", text: $key, prompt: Text("Optional"))
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
            }
            .formStyle(.grouped)

            if let error {
                Text(error).font(.callout).foregroundStyle(.red).padding(.horizontal, 20).padding(.bottom, 8)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add Endpoint") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty || baseUrl.isEmpty || chosen.isEmpty || working)
            }
            .padding(20)
        }
        .frame(width: 520, height: 560)
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
                var params: [String: Any] = [
                    "name": name, "baseUrl": baseUrl, "api": api,
                    "models": found.filter(chosen.contains).map { ["id": $0] },
                ]
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
