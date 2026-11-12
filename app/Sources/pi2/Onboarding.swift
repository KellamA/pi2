import SwiftUI

/// First launch: what the app is, connecting a model, and the three things worth knowing.
struct OnboardingView: View {
    @Bindable var model: AppModel
    @State private var page = 0
    @State private var local: [(name: String, url: String, models: [String])] = []
    @State private var looking = true
    @State private var adding: String?
    @Environment(\.openSettings) private var openSettings
    private var engine: EngineClient { model.engine }

    private var realModels: [ModelInfo] { engine.models.filter { $0.provider != "demo" } }
    /// The sign-ins most people have, in a fixed order; the rest are in Settings.
    private var subscriptions: [ProviderInfo] {
        ["anthropic", "openai", "xai", "github-copilot"].compactMap { id in
            engine.providers.first { $0.id == id && $0.oauth?.subscription == true }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case 0: welcome
                case 1: connect
                default: tips
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(28)
            Divider()
            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle().fill(index == page ? Color.piAccent : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                    }
                }
                .accessibilityLabel("Step \(page + 1) of 3")
                Spacer()
                if page > 0 { Button("Back") { page -= 1 } }
                if page < 2 {
                    Button(page == 1 && realModels.isEmpty ? "Skip for Now" : "Continue") { page += 1 }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Start Using pi²") { engine.perform("settings.finishOnboarding") }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 600, height: 500)
        .task { await findLocalServers() }
        .sheet(isPresented: Binding(get: { engine.signIn != nil }, set: { if !$0 { engine.cancelSignIn() } })) {
            SignInSheet(engine: engine)
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to pi²").font(.largeTitle.weight(.semibold))
            Text("A home for AI agents that keep working. Every step is saved as it happens, so a crash, a restart or quitting the app never loses a run.")
                .font(.title3).foregroundStyle(.secondary)
            point("person.2", "Agents with their own setup", "Give each agent a model, instructions and tools. They can hand work to each other.")
            point("hand.raised", "You stay in control", "Agents ask before changing files or running commands, and wait for you, even overnight.")
            point("clock.arrow.circlepath", "Always on", "Schedules, a menu bar icon and Quick Ask keep agents within reach while you do other things.")
        }
    }

    private var connect: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect a model").font(.title.weight(.semibold))
            if realModels.isEmpty {
                Text("pi² needs a model to think with. Pick any one; you can add more later in Settings.").foregroundStyle(.secondary)
            } else {
                Label("\(realModels.count) model\(realModels.count == 1 ? "" : "s") ready. You can add more, or continue.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if looking {
                        HStack { ProgressView().controlSize(.small); Text("Looking for model servers on this Mac…").foregroundStyle(.secondary) }
                    }
                    ForEach(local, id: \.url) { server in
                        let added = engine.providers.contains { $0.endpoint?.baseUrl == server.url }
                        option("desktopcomputer", "\(server.name) is running on this Mac", "\(server.models.count) model\(server.models.count == 1 ? "" : "s") · free and private") {
                            if added {
                                Label("Added", systemImage: "checkmark").foregroundStyle(.green)
                            } else {
                                Button(adding == server.url ? "Adding…" : "Use It") { add(server) }.disabled(adding != nil)
                            }
                        }
                    }
                    ForEach(subscriptions) { provider in
                        option("person.crop.circle.badge.checkmark", provider.oauth?.name ?? provider.name, "Sign in with a plan you already pay for") {
                            if provider.status?.type == "oauth" {
                                Label("Signed in", systemImage: "checkmark").foregroundStyle(.green)
                            } else {
                                Button("Sign In…") { engine.startSignIn(provider) }
                            }
                        }
                    }
                    option("key", "API key or your own server", "Any of 40 providers, or a server that speaks the OpenAI or Anthropic API") {
                        Button("Open Settings…") { openSettings() }
                    }
                }
            }
            Text("Without a model, pi² uses a scripted demo that shows how things work but cannot answer.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var tips: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Three things worth knowing").font(.title.weight(.semibold))
            point("command", "⌘K finds and starts anything", "Conversations, agents, commands and the text of every message.")
            point("bolt", "⌃⌥Space asks from anywhere", "A small prompt over whatever you are doing. The answer appears in place.")
            point("wrench.and.screwdriver", "You decide what agents may touch", "Each agent and conversation has a tool level: chat only, read files, ask first, or full access. Tools always work inside one folder.")
        }
    }

    private func point(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title2).foregroundStyle(Color.piAccent).frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func option(_ icon: String, _ title: String, _ detail: String, @ViewBuilder action: () -> some View) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            action()
        }
        .padding(10)
        .background(.background.secondary, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }

    /// Ask the usual local ports whether a model server is listening. Embedding-only models are left out.
    private func findLocalServers() async {
        for _ in 0..<40 where engine.status != .connected { try? await Task.sleep(for: .milliseconds(150)) }
        var found: [(String, String, [String])] = []
        for (name, url) in [("Ollama", "http://localhost:11434/v1"), ("LM Studio", "http://localhost:1234/v1")] {
            guard let result = try? await engine.call("endpoints.probe", ["baseUrl": url]) else { continue }
            let models = (result["models"]?.arrayValue ?? []).compactMap(\.stringValue).filter { !$0.lowercased().contains("embed") }
            if !models.isEmpty { found.append((name, url, models)) }
        }
        local = found
        looking = false
    }

    private func add(_ server: (name: String, url: String, models: [String])) {
        adding = server.url
        Task {
            defer { adding = nil }
            do {
                try await engine.call("endpoints.save", ["name": server.name, "baseUrl": server.url, "api": "openai-completions", "models": server.models.map { ["id": $0] }])
            } catch {
                engine.lastError = error.localizedDescription
            }
        }
    }
}
