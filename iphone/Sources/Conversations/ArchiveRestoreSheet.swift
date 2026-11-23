import PiModels
import SwiftUI

/// What restoring one conversation of a deleted project would do, on screen until the person restores it or cancels
/// (docs/projects.md, 3.6), as the Mac's Archive keeps it (`RestoreShown`).
struct ArchiveRestoreShown: Identifiable, Equatable {
    let conversation: Int
    let title: String
    let report: CarryOverReport
    var changed = false
    var id: String { "\(conversation):\(report.plan ?? "")" }

    private var project: CarryOverReport.Project? { report.projects.first }

    /// Where it goes, which agent it runs as, and what stays as it is: the Mac's sheet's words (`RestoreSheet.intro`).
    var intro: String {
        let name = project?.name ?? "a project"
        var line = "“\(title)” is restored into \(name), the project of its folder, with its sub-chats."
        if report.restoresProject == true { line += " That project is archived and will be restored too." }
        if let copy = project?.copies.first(where: { $0.template == report.rootAgent }) {
            line += copy.existing == nil
                ? " It runs as a new copy of its agent, \(copy.name)."
                : " It runs as the project's copy of its agent, \(copy.name)."
        }
        line += " Its folder, worktree and conversation-specific permissions do not change."
        return line
    }

    /// Every new copy that takes something a duplicate made by hand would not (docs/projects.md, 9.5), with what it takes.
    var secrets: [(name: String, takes: String)] {
        (project?.copies ?? []).filter { $0.existing == nil && ($0.allowEverything || !$0.variables.isEmpty) }.map { copy in
            var parts: [String] = []
            if copy.allowEverything { parts.append("Allow everything, so nothing it does is asked about") }
            if !copy.variables.isEmpty { parts.append("the values of \(copy.variables.joined(separator: ", "))") }
            return (copy.name, parts.joined(separator: "; and "))
        }
    }

    /// What else the engine says to know, and the copies that will not make worktrees or will start elsewhere.
    var notices: [String] {
        guard let project else { return [] }
        var lines: [String] = []
        for copy in project.copies where copy.worktreeOff {
            lines.append("\(copy.name) makes a worktree for each conversation, but this folder is not a git repository, so its copy will not.")
        }
        for copy in project.copies where copy.folder != nil {
            lines.append("New sub-chats handed to \(copy.name) will start in this project's folder, not in \(copy.folder!). Conversations already working stay where they are.")
        }
        return lines + project.notices
    }

    static func == (left: ArchiveRestoreShown, right: ArchiveRestoreShown) -> Bool {
        left.id == right.id && left.changed == right.changed && left.report == right.report
    }
}

/// The sheet of a restore: what it would do, before anything is done, with Restore and Cancel.
struct ArchiveRestoreSheet: View {
    let shown: ArchiveRestoreShown
    let working: Bool
    let go: () -> Void
    let cancel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if shown.changed {
                        Label("What the restore would do has changed since you looked. This is what it would do now.", systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                    }
                    Text(shown.intro)
                }
                if !shown.secrets.isEmpty {
                    Section {
                        ForEach(shown.secrets, id: \.name) { secret in
                            Text("\(secret.name): \(secret.takes)")
                        }
                    } header: {
                        Label("These copies take more than a duplicate would", systemImage: "exclamationmark.shield")
                            .foregroundStyle(.red)
                    } footer: {
                        Text("Each takes them from the agent it is a copy of, so the conversation goes on as before.")
                    }
                }
                if !shown.notices.isEmpty {
                    Section("To know") {
                        ForEach(shown.notices, id: \.self) { notice in
                            Label(notice, systemImage: "exclamationmark.triangle")
                        }
                    }
                }
            }
            .navigationTitle("Restore to a Project?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel, action: cancel)
                        .disabled(working)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Restore", action: go)
                        .disabled(working)
                }
            }
        }
    }
}
