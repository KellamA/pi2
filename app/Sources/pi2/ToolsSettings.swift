import SwiftUI

/// MCP servers: tool providers the person connects and then gives to the agents they choose.
struct ToolsSettings: View {
    let engine: EngineClient
    @State private var adding = false

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
                            Button("Reconnect") { engine.perform("mcp.reconnect", ["id": server.id]) }
                            Button("Remove", role: .destructive) { engine.perform("mcp.delete", ["id": server.id]) }
                        }
                        Text(server.transport == "stdio" ? ([server.command ?? ""] + (server.args ?? [])).joined(separator: " ") : (server.url ?? ""))
                            .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
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
                Text("A server's tools go to the agents you tick it for, under Extra tools in the agent's settings. With “Ask first”, tools a server does not mark as read-only wait for your approval. A local server is a program that runs on this Mac with your permissions; only add ones you trust.")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $adding) { McpServerSheet(engine: engine) }
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
