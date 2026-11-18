import SwiftUI

/// MCP servers: tool providers the person connects and then gives to the agents they choose. And what agents are asked
/// to put in the commits they make.
struct ToolsSettings: View {
    let engine: EngineClient
    @State private var adding = false
    /// The server whose variables are being looked at.
    @State private var variablesOf: McpServer?

    var body: some View {
        Form {
            Section {
                if engine.mcpServers.isEmpty {
                    Text("No servers yet.").foregroundStyle(.secondary)
                }
                ForEach(engine.mcpServers) { server in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Circle().fill(color(server.status)).frame(width: 8, height: 8)
                            Text(server.name)
                            Text(statusText(server)).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if server.transport == "stdio" {
                                Button("Variables…") { variablesOf = server }
                                    .help("Environment variables this server’s program is started with, such as a token it needs")
                            }
                            Button("Reconnect") { engine.perform("mcp.reconnect", ["id": server.id]) }
                            Button("Remove", role: .destructive) { engine.perform("mcp.delete", ["id": server.id]) }
                        }
                        Text(server.transport == "stdio" ? ([server.command ?? ""] + (server.args ?? [])).joined(separator: " ") : (server.url ?? ""))
                            .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        if let variables = server.variables, !variables.isEmpty {
                            Text("Variables: " + variables.map(\.name).joined(separator: ", "))
                                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                        }
                        if let error = server.error {
                            Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
                        }
                        if !server.tools.isEmpty {
                            Text(server.tools.map(\.name).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
                Button("Add Server…") { adding = true }
            } header: {
                Text("MCP servers")
            } footer: {
                Text("A server's tools go to the agents you tick it for, under Extra tools in the agent's settings. With “Ask first”, tools a server does not mark as read-only wait for your approval. A local server is a program that runs on this Mac with your permissions; only add ones you trust.").formFooter()
            }
            .id(SettingsSection.servers)
            CoauthorSettings(engine: engine)
                .id(SettingsSection.commits)
        }
        .formStyle(.grouped)
        .settingsPage(.tools)
        .sheet(isPresented: $adding) { McpServerSheet(engine: engine) }
        .sheet(item: $variablesOf) { server in McpVariablesSheet(engine: engine, serverID: server.id) }
        #if PI2_DEVELOPMENT
        .task {
            // The servers arrive a moment after the tab appears.
            guard let wanted = SettingsLaunch.takeVariablesSheet() else { return }
            for _ in 0..<100 {
                if let server = engine.mcpServers.first(where: { $0.id == wanted }) {
                    variablesOf = server
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        #endif
    }

    private func color(_ status: String) -> Color {
        switch status {
        case "connected": .green
        case "connecting": .yellow
        case "error": .red
        default: .gray
        }
    }

    private func statusText(_ server: McpServer) -> String {
        switch server.status {
        case "connected": "\(server.tools.count) tool\(server.tools.count == 1 ? "" : "s")"
        case "connecting": "connecting…"
        case "error": "not connected"
        default: "off"
        }
    }
}

/// A server's own environment variables (issue #273), which its program is started with: listed by name, set, replaced
/// and removed as an agent's are. Each change starts the server again with them, letting a call running on it finish.
struct McpVariablesSheet: View {
    let engine: EngineClient
    let serverID: String
    @Environment(\.dismiss) private var dismiss

    private var server: McpServer? { engine.mcpServers.first { $0.id == serverID } }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Label("The server’s program can read these values, and so can whatever it starts.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.warn)
                    VariablesEditor(
                        variables: server?.variables ?? [],
                        unsetText: "no value: the server does not get it",
                        removeHelp: "the server is started again without it",
                        onSet: { name, value in _ = try await engine.call("mcp.setVariable", ["id": serverID, "name": name, "value": value]) },
                        onRemove: { name in _ = try await engine.call("mcp.removeVariable", ["id": serverID, "name": name]) }
                    )
                } header: {
                    Text("Variables for \(server?.name ?? "the server")")
                } footer: {
                    Text("pi² starts the server’s program with these as environment variables: for example a token it needs, which would otherwise have to go in its command. Only this server gets them, not agents’ commands. Values are kept in your macOS Keychain, never in pi²’s files or backups, and cannot be shown here again, only replaced. Removing the server removes them. Each change applies at once: the server is started again with it, and a call running on it finishes first.").formFooter()
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                // Not the default button: Return in a value field adds or saves the variable, never closes the sheet.
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
        }
        .frame(width: 560, height: 380)
    }
}

struct McpServerSheet: View {
    let engine: EngineClient
    @State private var name = ""
    @State private var transport = "stdio"
    @State private var commandLine = ""
    @State private var url = ""
    @State private var token = ""
    @State private var error: String?
    @State private var working = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $name, prompt: Text("GitHub"))
                Picker("Runs", selection: $transport) {
                    Text("On this Mac").tag("stdio")
                    Text("At a URL").tag("http")
                }
                .pickerStyle(.segmented)
                if transport == "stdio" {
                    TextField("Command", text: $commandLine, prompt: Text("npx -y @modelcontextprotocol/server-filesystem ~/Documents"))
                        .font(.system(.body, design: .monospaced))
                } else {
                    TextField("URL", text: $url, prompt: Text("https://mcp.example.com/mcp"))
                    SecureField("Access token", text: $token, prompt: Text("Optional"))
                }
            }
            .formStyle(.grouped)
            if let error { Text(error).font(.callout).foregroundStyle(.red).padding(.horizontal, 20) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(working ? "Connecting…" : "Add Server") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(20)
        }
        .frame(width: 520, height: 300)
    }

    /// Splits a command line on spaces, keeping quoted parts together.
    static func words(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        for character in line {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == " " {
                if !current.isEmpty { words.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    private func save() {
        working = true
        error = nil
        var params: [String: Any] = ["name": name, "transport": transport]
        if transport == "stdio" {
            let words = Self.words(commandLine).map { NSString(string: $0).expandingTildeInPath }
            params["command"] = words.first ?? ""
            params["args"] = Array(words.dropFirst())
        } else {
            params["url"] = url
            if !token.isEmpty { params["token"] = token }
        }
        Task {
            defer { working = false }
            do {
                try await engine.call("mcp.save", params)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
