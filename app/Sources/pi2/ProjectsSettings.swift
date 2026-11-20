import SwiftUI

// Settings › General › Projects (preview) (docs/projects.md, section 2), and the report of what carrying over would do,
// shown before it runs (9.8).

struct ProjectsPreviewSettings: View {
    let engine: EngineClient
    @State private var report: ShownReport?
    @State private var working = false
    @State private var error: String?

    /// A report on screen; `changed` when it replaced one the person was looking at.
    struct ShownReport: Identifiable {
        let report: CarryOverReport
        var changed = false
        var id: String { report.plan ?? "none" }
    }

    var body: some View {
        let store = engine.projects
        Section {
            Toggle("Show projects in place of agents and conversations", isOn: Binding(
                get: { store.preview },
                set: { on in if on { look() } else { turnOff() } }
            ))
            .disabled(working || engine.status != .connected)
            if let error { Text(error).font(.callout).foregroundStyle(Theme.bad) }
            if store.preview, let pending = store.carryOver?.secretsPending, !pending.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(pending, id: \.copy) { item in
                        Text("\(item.variables.count == 1 ? "1 of \(item.name)’s variables has" : "\(item.variables.count) of \(item.name)’s variables have") not been copied from the agent it was made from, in \(item.project).\(item.error.map { " \($0)" } ?? "")")
                            .font(.callout).foregroundStyle(Theme.warn)
                    }
                    Button("Try Again") { retrySecrets() }
                        .disabled(working)
                }
            }
        } header: {
            Text("Projects (preview)")
        } footer: {
            Text("Projects group your conversations by their folder, each with an orchestrator that hands the work to the project’s agents. Turning this on first shows what would be carried over into projects, and does it only if you go ahead. Turning it off shows everything as it was: nothing is undone or deleted either way.").formFooter()
        }
        .sheet(item: $report) { shown in
            CarryOverSheet(shown: shown, working: working) { go(shown.report) } cancel: { report = nil }
        }
    }

    /// Asks the engine what carrying over would do, and shows it; with nothing to carry over, turns the preview on.
    private func look() {
        error = nil
        working = true
        Task {
            defer { working = false }
            do {
                let found = try CarryOverReport(try await engine.call("projects.carryOver", ["dryRun": true]))
                if found.plan == nil {
                    _ = try await engine.call("projects.setPreview", ["on": true])
                } else {
                    report = ShownReport(report: found)
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Runs the plan the person was shown. If it changed meanwhile, the engine turns nothing on and sends the new report.
    private func go(_ shown: CarryOverReport) {
        working = true
        Task {
            defer { working = false }
            do {
                _ = try await engine.call("projects.setPreview", ["on": true, "plan": shown.plan as Any? ?? NSNull()])
                report = nil
            } catch let refusal as EngineError {
                if let data = refusal.data, let changed = try? CarryOverReport(.object(data)) {
                    report = ShownReport(report: changed, changed: true)
                } else {
                    report = nil
                    error = refusal.localizedDescription
                }
            } catch {
                report = nil
                self.error = error.localizedDescription
            }
        }
    }

    private func turnOff() {
        error = nil
        working = true
        Task {
            defer { working = false }
            do {
                _ = try await engine.call("projects.setPreview", ["on": false])
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func retrySecrets() {
        working = true
        Task {
            defer { working = false }
            do {
                _ = try await engine.call("projects.retrySecrets")
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// What carrying over would do: the projects, what goes into each, the copies that take an agent's variables or Allow
/// everything, by name, and each warning. Nothing is done until the person goes ahead.
struct CarryOverSheet: View {
    let shown: ProjectsPreviewSettings.ShownReport
    let working: Bool
    let go: () -> Void
    let cancel: () -> Void
    private var report: CarryOverReport { shown.report }

    /// Every copy that takes something that is not copied when an agent is duplicated by hand (9.5).
    private var secretCopies: [(project: String, copy: CarryOverReport.Project.Copy)] {
        report.projects.flatMap { project in
            project.copies.filter { $0.existing == nil && ($0.allowEverything || !$0.variables.isEmpty) }.map { (project.name, $0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Turn on Projects?").font(.title2.weight(.semibold))
                if shown.changed {
                    Text("What would be carried over has changed since you looked. This is what it would do now.")
                        .foregroundStyle(Theme.warn)
                }
                Text("pi² puts your conversations into projects by their folder, with a copy in each project of the agents they ran as. Your agents become templates, as they are. Nothing is deleted, and the old screens read nothing that changes: turning Projects off shows everything as it was. A backup is made first.")
                    .foregroundStyle(Theme.tx2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !secretCopies.isEmpty { secrets }
                    ForEach(report.projects) { project in
                        ProjectPlanView(project: project)
                    }
                    leftOut
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(report.projects.count == 1 ? "Carry Over into 1 Project" : "Carry Over into \(report.projects.count) Projects", action: go)
                    .keyboardShortcut(.defaultAction)
                    .disabled(working)
            }
            .padding(16)
        }
        .frame(width: 560, height: 560)
    }

    /// The copies that take Allow everything or variables' values, by name, before anything else.
    private var secrets: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("These copies take more than a duplicate would", systemImage: "exclamationmark.shield").font(.headline).foregroundStyle(Theme.bad)
            ForEach(secretCopies, id: \.copy.template) { item in
                Text("\(item.copy.name) in \(item.project): \(Self.takes(item.copy))")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Each takes them from the agent it is a copy of, so its conversations go on as before.").formFooter()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bad.opacity(0.08), in: .rect(cornerRadius: 8))
    }

    static func takes(_ copy: CarryOverReport.Project.Copy) -> String {
        var parts: [String] = []
        if copy.allowEverything { parts.append("Allow everything, so nothing it does is asked about") }
        if !copy.variables.isEmpty { parts.append("the values of \(copy.variables.joined(separator: ", "))") }
        return parts.joined(separator: "; and ")
    }

    private var leftOut: some View {
        let left = report.leftOut
        var lines: [String] = []
        if report.already > 0 { lines.append(report.already == 1 ? "1 conversation is already in a project and stays there." : "\(report.already) conversations are already in a project and stay there.") }
        if left.chats > 0 { lines.append(left.chats == 1 ? "1 chat stays in chat mode." : "\(left.chats) chats stay in chat mode.") }
        if left.deletedProject > 0 { lines.append(left.deletedProject == 1 ? "1 conversation of a deleted project stays where it is." : "\(left.deletedProject) conversations of deleted projects stay where they are.") }
        if left.notesLeft > 0 { lines.append(left.notesLeft == 1 ? "1 note of a deleted agent stays where it is." : "\(left.notesLeft) notes of deleted agents stay where they are.") }
        return VStack(alignment: .leading, spacing: 4) {
            if !lines.isEmpty {
                Text("Left as they are").font(.headline)
                ForEach(lines, id: \.self) { Text($0).foregroundStyle(Theme.tx2) }
            }
        }
    }
}

/// One project in the report: where it comes from, what goes into it and what to know.
private struct ProjectPlanView: View {
    let project: CarryOverReport.Project

    private var status: String {
        if project.existing == nil { return project.archived ? "New, archived: everything in it is archived" : "New" }
        return project.adopted ? "Your project for this folder" : "Already made"
    }

    private var contents: String {
        var parts: [String] = []
        if project.conversations > 0 { parts.append(project.conversations == 1 ? "1 conversation" : "\(project.conversations) conversations") }
        if project.archivedConversations > 0 { parts.append("\(project.archivedConversations) archived") }
        if project.subChats > 0 { parts.append(project.subChats == 1 ? "1 sub-chat" : "\(project.subChats) sub-chats") }
        if project.notes > 0 { parts.append(project.notes == 1 ? "1 note" : "\(project.notes) notes") }
        return parts.isEmpty ? "Nothing new" : parts.joined(separator: ", ")
    }

    private var orchestrator: String? {
        guard let orchestrator = project.orchestrator else { return nil }
        if let title = orchestrator.title {
            return "Orchestrator: the agent of “\(title.isEmpty ? "New conversation" : title)”, which goes on as its conversation"
        }
        return "Orchestrator: pi²’s default orchestrator, with a new conversation when you first open it"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(project.name).font(.headline)
                Text(status).font(.caption).foregroundStyle(Theme.tx3)
            }
            Text(project.key == "none" ? "No folder" : (project.key as NSString).abbreviatingWithTildeInPath)
                .font(Theme.mono).foregroundStyle(Theme.tx3).lineLimit(1).truncationMode(.middle)
            Text(contents)
            if let orchestrator { Text(orchestrator).foregroundStyle(Theme.tx2).fixedSize(horizontal: false, vertical: true) }
            if !project.copies.isEmpty {
                let made = project.copies.filter { $0.existing == nil }.map(\.name)
                let kept = project.copies.filter { $0.existing != nil }.map(\.name)
                if !made.isEmpty { Text("Copies of \(made.joined(separator: ", "))").foregroundStyle(Theme.tx2) }
                if !kept.isEmpty { Text("Uses its copies of \(kept.joined(separator: ", "))").foregroundStyle(Theme.tx2) }
            }
            ForEach(project.copies.filter { $0.worktreeOff }) { copy in
                warning("\(copy.name) makes a worktree for each conversation, but this folder is not a git repository, so its copy will not.")
            }
            ForEach(project.copies.filter { $0.folder != nil }) { copy in
                warning("New sub-chats handed to \(copy.name) will start in this project’s folder, not in \((copy.folder! as NSString).abbreviatingWithTildeInPath). Conversations already working stay where they are.")
            }
            ForEach(project.notices, id: \.self) { warning($0) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private func warning(_ text: String) -> some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warn) }
            .font(.callout)
    }
}
