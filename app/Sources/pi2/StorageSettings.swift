import AppKit
import BrowserKit
import PiModels
import SwiftUI
import UniformTypeIdentifiers

/// Saving things out of the app: one conversation as a file, or everything as a backup.
@MainActor
enum StorageActions {
    static func export(_ conversation: ConversationSummary, format: String, engine: EngineClient) {
        guard let url = FilePanels.save("conversation-export", configure: { panel in
            let name = conversation.title.isEmpty ? "Conversation" : conversation.title
            panel.nameFieldStringValue = String(name.prefix(60)).replacingOccurrences(of: "/", with: "-") + (format == "json" ? ".json" : ".md")
            panel.allowedContentTypes = [format == "json" ? .json : (UTType(filenameExtension: "md") ?? .plainText)]
        }) else { return }
        Task {
            do {
                let result = try await engine.call("conversation.export", ["id": conversation.id, "format": format])
                try (result["text"]?.stringValue ?? "").write(to: url, atomically: true, encoding: .utf8)
            } catch {
                engine.lastError = error.localizedDescription
            }
        }
    }

    static func chooseFolder(_ name: String, prompt: String, message: String) -> URL? {
        FilePanels.open(name, selecting: .folders) { panel in
            panel.canCreateDirectories = true
            panel.prompt = prompt
            panel.message = message
        }?.first
    }
}

struct StorageSettings: View {
    let engine: EngineClient
    @State private var message: String?
    @State private var failed = false
    @State private var working = false
    @State private var restoreFrom: URL?
    /// What the engine says of the last backup when it did not finish (#792): cut off by the engine stopping, or failed.
    @State private var unfinished: String?
    /// What agents' presented pictures and pages keep in the data folder (`engine.info`'s `presented`, #946).
    @State private var presented: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Data folder") {
                    HStack {
                        Text(engine.dataFolder.path).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([engine.dataFolder]) }
                    }
                }
                if let presented {
                    LabeledContent("Presented pictures and pages") {
                        Text(presented).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            } footer: {
                Text("Conversations, agents, schedules and settings live here in one database. Keys and sign-ins live in your macOS Keychain.").formFooter()
            }
            .id(SettingsSection.folder)
            Section {
                Button(working ? "Working…" : "Back Up Now…") { backUp() }.disabled(working)
                Button("Restore From Backup…") {
                    restoreFrom = StorageActions.chooseFolder("restore-backup", prompt: "Restore", message: "Choose a pi2-backup folder to restore.")
                }
                .disabled(working)
                if let message {
                    Text(message).font(.callout).foregroundStyle(failed ? .red : .secondary).textSelection(.enabled)
                } else if let unfinished {
                    Text(unfinished).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                }
            } header: {
                Text("Backup")
            } footer: {
                Text("A backup is a folder with a copy of everything except keys and sign-ins. It can be made while agents are working. Restoring replaces what is here now; the replaced data is moved aside inside the data folder, not deleted.").formFooter()
            }
            .id(SettingsSection.backup)
        }
        .formStyle(.grouped)
        .settingsPage(.storage)
        .task { await loadStatus() }
        .confirmationDialog("Replace everything with this backup?", isPresented: Binding(get: { restoreFrom != nil }, set: { if !$0 { restoreFrom = nil } })) {
            Button("Restore", role: .destructive) { if let folder = restoreFrom { restore(folder) } }
            Button("Cancel", role: .cancel) { restoreFrom = nil }
        } message: {
            Text("Running work is stopped. Your current conversations, agents and schedules are moved into a “before-restore” folder inside the data folder.")
        }
    }

    private func backUp() {
        guard let folder = StorageActions.chooseFolder("create-backup", prompt: "Back Up Here", message: "Choose where to put the backup folder.") else { return }
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
            await loadStatus()
        }
    }

    /// The line for a backup that did not finish, from `engine.info`'s `backup`; nothing when the last one finished.
    private func loadStatus() async {
        let result = try? await engine.call("engine.info")
        presented = result.flatMap { Self.presentedLine($0["presented"]) }
        guard let result, let last = result["backup"]?["unfinished"], case .object = last else {
            unfinished = nil
            return
        }
        let why = last["reason"]?.stringValue.map { $0.replacingOccurrences(of: #"[.\s]+$"#, with: "", options: .regularExpression) } ?? "pi² stopped while making it"
        var when = ""
        if case .number(let ms)? = last["startedAt"] {
            when = ", started \(Date(timeIntervalSince1970: ms / 1000).formatted(date: .abbreviated, time: .shortened))"
        }
        let folder = last["folder"]?.stringValue.map { " in \(URL(fileURLWithPath: $0).lastPathComponent)" } ?? ""
        unfinished = "The last backup\(folder)\(when), did not finish: \(why). What it had copied is not a backup and is removed. Back up again to have one."
    }

    /// "312 MB, in 14 conversations", from `engine.info`'s `presented: { bytes, conversations }`; nil from an engine that
    /// does not say. Nothing limits it above one conversation yet: the line only shows the total.
    static func presentedLine(_ value: JSONValue?) -> String? {
        guard case .number(let bytes)? = value?["bytes"], case .number(let count)? = value?["conversations"], bytes >= 0, count >= 0 else { return nil }
        if count == 0 { return "None yet" }
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        let conversations = Int(count)
        return "\(size), in \(conversations) conversation\(conversations == 1 ? "" : "s")"
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
