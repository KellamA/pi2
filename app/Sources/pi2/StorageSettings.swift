import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Saving things out of the app: one conversation as a file, or everything as a backup.
@MainActor
enum StorageActions {
    static func export(_ conversation: ConversationSummary, format: String, engine: EngineClient) {
        let panel = NSSavePanel()
        let name = conversation.title.isEmpty ? "Conversation" : conversation.title
        panel.nameFieldStringValue = String(name.prefix(60)).replacingOccurrences(of: "/", with: "-") + (format == "json" ? ".json" : ".md")
        panel.allowedContentTypes = [format == "json" ? .json : (UTType(filenameExtension: "md") ?? .plainText)]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let result = try await engine.call("conversation.export", ["id": conversation.id, "format": format])
                try (result["text"]?.stringValue ?? "").write(to: url, atomically: true, encoding: .utf8)
            } catch {
                engine.lastError = error.localizedDescription
            }
        }
    }

    static func chooseFolder(prompt: String, message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = prompt
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }
}

struct StorageSettings: View {
    let engine: EngineClient
    @State private var message: String?
    @State private var failed = false
    @State private var working = false
    @State private var restoreFrom: URL?

    var body: some View {
        Form {
            Section {
                LabeledContent("Data folder") {
                    HStack {
                        Text(engine.dataFolder.path).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([engine.dataFolder]) }
                    }
                }
            } footer: {
                Text("Conversations, agents, schedules and settings live here in one database. Keys and sign-ins live in your macOS Keychain.").formFooter()
            }
            Section {
                Button(working ? "Working…" : "Back Up Now…") { backUp() }.disabled(working)
                Button("Restore From Backup…") {
                    restoreFrom = StorageActions.chooseFolder(prompt: "Restore", message: "Choose a pi2-backup folder to restore.")
                }
                .disabled(working)
                if let message {
                    Text(message).font(.callout).foregroundStyle(failed ? .red : .secondary).textSelection(.enabled)
                }
            } header: {
                Text("Backup")
            } footer: {
                Text("A backup is a folder with a copy of everything except keys and sign-ins. It can be made while agents are working. Restoring replaces what is here now; the replaced data is moved aside inside the data folder, not deleted.").formFooter()
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Replace everything with this backup?", isPresented: Binding(get: { restoreFrom != nil }, set: { if !$0 { restoreFrom = nil } })) {
            Button("Restore", role: .destructive) { if let folder = restoreFrom { restore(folder) } }
            Button("Cancel", role: .cancel) { restoreFrom = nil }
        } message: {
            Text("Running work is stopped. Your current conversations, agents and schedules are moved into a “before-restore” folder inside the data folder.")
        }
    }

    private func backUp() {
        guard let folder = StorageActions.chooseFolder(prompt: "Back Up Here", message: "Choose where to put the backup folder.") else { return }
        working = true
        Task {
            defer { working = false }
            do {
                let result = try await engine.call("backup.create", ["directory": folder.path])
                failed = false
                message = "Backed up to \(result["path"]?.stringValue ?? folder.path)"
            } catch {
                failed = true
                message = error.localizedDescription
            }
        }
    }

    private func restore(_ folder: URL) {
        restoreFrom = nil
        working = true
        Task {
            defer { working = false }
            do {
                try await engine.restoreBackup(from: folder)
                failed = false
                message = "Restored from \(folder.lastPathComponent). The engine is starting again."
            } catch {
                failed = true
                message = error.localizedDescription
            }
        }
    }
}
