import AppKit
import SwiftUI

// The branch tracker: which branch each conversation's folder is on, whether that is a worktree of its own, and how
// the branch stands. The engine looks every few seconds (worktrees.ts); this file shows what it found and offers the
// worktree actions. See docs/worktrees.md.

extension BranchStatus {
    /// The icon's colour, most pressing state first.
    var color: Color {
        switch state {
        case "conflict": Theme.bad
        case "changes": Theme.warn
        case "ahead", "behind": Theme.ahead
        case "merged": Theme.merged
        case "clean": Theme.ok
        default: Theme.tx3 // missing, detached
        }
    }

    /// The state in a word or two, for a tag.
    var stateTitle: String {
        switch state {
        case "conflict": operation.map { "\($0) stopped" } ?? "conflicts"
        case "changes": "\(changes) changed"
        case "ahead": upstream == nil ? "\(unmerged ?? ahead) new" : "\(ahead) to push"
        case "behind": "\(behind) behind"
        case "merged": "merged"
        case "clean": "clean"
        case "missing": "missing"
        case "detached": "detached"
        default: state
        }
    }

    var tone: Tag.Tone {
        switch state {
        case "conflict": .bad
        case "changes": .warn
        case "ahead", "behind": .ahead
        case "merged": .merged
        case "clean": .ok
        default: .neutral
        }
    }

    /// The branch's name, or what HEAD is when it is on none.
    var name: String { branch ?? head.map { "detached at \($0)" } ?? "no branch" }

    /// One line per fact, for the details and the tooltip.
    var facts: [String] {
        var lines: [String] = []
        if state == "missing" { lines.append("The worktree’s folder is gone. Remove the worktree to let git forget it.") }
        if conflicts > 0 { lines.append("\(conflicts) file\(conflicts == 1 ? "" : "s") with unresolved conflicts") }
        if let operation, conflicts == 0 { lines.append("A \(operation) stopped half way") }
        if changes > 0 { lines.append("\(changes) uncommitted change\(changes == 1 ? "" : "s")") }
        if let upstream {
            switch (ahead, behind) {
            case (0, 0): lines.append("Up to date with \(upstream)")
            case (let a, 0): lines.append("\(a) commit\(a == 1 ? "" : "s") not pushed to \(upstream)")
            case (0, let b): lines.append("\(b) commit\(b == 1 ? "" : "s") behind \(upstream)")
            case (let a, let b): lines.append("\(a) ahead of \(upstream), \(b) behind")
            }
        } else if state != "missing", branch != nil {
            lines.append("Not pushed anywhere yet")
        }
        if state == "merged", let base { lines.append("Everything on it is on \(base)") }
        else if let unmerged, let base, unmerged > 0 { lines.append("\(unmerged) commit\(unmerged == 1 ? "" : "s") not on \(base) yet") }
        return lines
    }

    var whereText: String {
        if managed { return "Its own worktree of \(repo)" }
        if worktree { return "A worktree of \(repo)" }
        return "The main checkout of \(repo)"
    }

    var help: String { ([name, whereText] + facts).joined(separator: "\n") }
}

/// The branch icon: a plain branch for a repository's main checkout, a boxed one for a worktree.
struct BranchIcon: View {
    let status: BranchStatus
    var size: CGFloat = 11

    var body: some View {
        Image(systemName: "arrow.triangle.branch")
            .font(.system(size: status.worktree ? size - 2.5 : size, weight: .semibold))
            .foregroundStyle(status.color)
            .frame(width: size + 4, height: size + 4)
            .overlay {
                if status.worktree {
                    RoundedRectangle(cornerRadius: 3.5).strokeBorder(status.color.opacity(0.85), lineWidth: 1.2)
                }
            }
            .accessibilityLabel("\(status.worktree ? "Worktree" : "Branch") \(status.name), \(status.stateTitle)")
    }
}

/// The icon on a conversation's row in the sidebar; clicking it shows the details.
struct BranchBadge: View {
    let engine: EngineClient
    let conversationID: Int
    let status: BranchStatus
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            BranchIcon(status: status).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(status.help)
        .popover(isPresented: $showing, arrowEdge: .trailing) {
            BranchDetails(engine: engine, conversationID: conversationID, status: status) { showing = false }
        }
    }
}

/// What the tracker knows about one conversation's branch, and what can be done about it.
struct BranchDetails: View {
    let engine: EngineClient
    let conversationID: Int
    let status: BranchStatus
    var done: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                BranchIcon(status: status, size: 13)
                Text(status.name).font(.system(size: 13, weight: .semibold, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Tag(status.stateTitle, status.tone)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(status.whereText).foregroundStyle(Theme.tx2)
                Text(status.root).font(Theme.mono).foregroundStyle(Theme.tx3).lineLimit(1).truncationMode(.head).textSelection(.enabled)
            }
            if !status.facts.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(status.facts, id: \.self) { fact in
                        Label(fact, systemImage: "circle.fill").labelStyle(BulletLabel())
                    }
                }
                .font(.callout)
            }
            Divider()
            HStack(spacing: 6) {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: status.root)]) }
                    .disabled(status.state == "missing")
                if let branch = status.branch {
                    Button("Copy Name") { copy(branch) }.help("Copy the branch name")
                }
                Spacer(minLength: 8)
                if status.managed {
                    Button("Remove Worktree…") {
                        done()
                        WorktreeDialogs.shared.remove(conversationID, status: status)
                    }
                    .buttonStyle(.piDanger)
                } else {
                    Button("New Worktree…") {
                        done()
                        WorktreeDialogs.shared.create(conversationID, engine: engine)
                    }
                    .help("Move this conversation into a checkout of its own on a new branch, so other agents can work in this repository at the same time")
                }
            }
            .buttonStyle(.piSecondary)
        }
        .font(.system(size: 12.5))
        .padding(14)
        .frame(width: 400, alignment: .leading)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct BulletLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon.font(.system(size: 4)).foregroundStyle(Theme.tx3).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 3 }
            configuration.title
        }
    }
}

/// The branch in a conversation's toolbar: its name, coloured by how it stands, with the details in its menu.
struct BranchMenu: View {
    let engine: EngineClient
    let id: Int
    let status: BranchStatus

    var body: some View {
        Menu {
            Text(status.whereText)
            ForEach(status.facts, id: \.self) { Text($0) }
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: status.root)]) }
                .disabled(status.state == "missing")
            if let branch = status.branch {
                Button("Copy Branch Name") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(branch, forType: .string)
                }
            }
            Divider()
            if status.managed {
                Button("Remove Worktree…") { WorktreeDialogs.shared.remove(id, status: status) }
            } else {
                Button("New Worktree…") { WorktreeDialogs.shared.create(id, engine: engine) }
            }
        } label: {
            HStack(spacing: 5) {
                BranchIcon(status: status)
                Text(status.branch ?? status.head ?? "detached").lineLimit(1).truncationMode(.middle).frame(maxWidth: 170)
            }
        }
        .help(status.help)
    }
}

// MARK: - Making and removing a worktree

/// The questions asked before making or removing a worktree. Held here, not in a view, so the sidebar, the toolbar
/// and the Branches page can all ask, and one place shows the dialog (see `worktreeDialogs`).
@MainActor
@Observable
final class WorktreeDialogs {
    static let shared = WorktreeDialogs()

    struct Creating: Equatable { let id: Int; var branch: String }
    struct Removing: Equatable { let id: Int; let status: BranchStatus }

    var creating: Creating?
    var removing: Removing?
    /// Said after a worktree was removed but its branch kept.
    var notice: String?

    func create(_ id: Int, engine: EngineClient) {
        creating = Creating(id: id, branch: "")
        Task {
            if let suggested = try? await engine.call("worktree.suggest", ["id": id])["branch"]?.stringValue, creating?.id == id, creating?.branch == "" {
                creating?.branch = suggested
            }
        }
    }

    func remove(_ id: Int, status: BranchStatus) { removing = Removing(id: id, status: status) }
}

private struct WorktreeDialogsModifier: ViewModifier {
    let engine: EngineClient
    @Bindable var dialogs = WorktreeDialogs.shared

    func body(content: Content) -> some View {
        content
            .alert("New worktree", isPresented: Binding(get: { dialogs.creating != nil }, set: { if !$0 { dialogs.creating = nil } })) {
                TextField("Branch", text: Binding(get: { dialogs.creating?.branch ?? "" }, set: { dialogs.creating?.branch = $0 }))
                Button("Create") {
                    if let creating = dialogs.creating {
                        var params: [String: Any] = ["id": creating.id]
                        let branch = creating.branch.trimmingCharacters(in: .whitespaces)
                        if !branch.isEmpty { params["branch"] = branch }
                        engine.perform("worktree.create", params)
                    }
                    dialogs.creating = nil
                }
                Button("Cancel", role: .cancel) { dialogs.creating = nil }
            } message: {
                Text("The conversation moves into a checkout of its own on this branch, made from where its folder is now. Other agents can keep working in the repository meanwhile. An existing branch is checked out as it is.")
            }
            .alert("Worktree removed", isPresented: Binding(get: { dialogs.notice != nil }, set: { if !$0 { dialogs.notice = nil } })) {
                Button("OK") { dialogs.notice = nil }
            } message: {
                Text(dialogs.notice ?? "")
            }
            .confirmationDialog(
                "Remove the worktree for \(dialogs.removing?.status.branch ?? "this conversation")?",
                isPresented: Binding(get: { dialogs.removing != nil }, set: { if !$0 { dialogs.removing = nil } })
            ) {
                if let removing = dialogs.removing {
                    let dirty = removing.status.changes > 0 || removing.status.conflicts > 0
                    if dirty {
                        Button("Remove and Discard Changes", role: .destructive) { remove(removing, force: true, deleteBranch: false) }
                    } else {
                        Button("Remove Worktree, Keep Branch") { remove(removing, force: false, deleteBranch: false) }
                        Button("Remove Worktree and Branch", role: .destructive) { remove(removing, force: false, deleteBranch: true) }
                    }
                    Button("Cancel", role: .cancel) { dialogs.removing = nil }
                }
            } message: {
                if let removing = dialogs.removing {
                    let dirty = removing.status.changes > 0 || removing.status.conflicts > 0
                    Text(dirty
                        ? "It has \(removing.status.changes + removing.status.conflicts) uncommitted changes, which would be lost. Commit them first to keep them. The branch is kept."
                        : "The conversation goes back to the folder it worked in before. A branch with commits that are not merged is kept either way.")
                }
            }
    }

    private func remove(_ removing: WorktreeDialogs.Removing, force: Bool, deleteBranch: Bool) {
        dialogs.removing = nil
        Task {
            do {
                let result = try await engine.call("worktree.remove", ["id": removing.id, "force": force, "deleteBranch": deleteBranch])
                if let note = result["note"]?.stringValue { dialogs.notice = note }
            } catch {
                engine.lastError = error.localizedDescription
            }
        }
    }
}

extension View {
    /// Shows the worktree questions asked from anywhere in the window.
    func worktreeDialogs(engine: EngineClient) -> some View { modifier(WorktreeDialogsModifier(engine: engine)) }
}

// MARK: - The Branches page

/// Every conversation whose folder is in a git repository, by repository: which branch it is on, whether in a worktree
/// of its own, and how the branch stands.
struct BranchesView: View {
    @Bindable var model: AppModel
    private var engine: EngineClient { model.engine }

    private struct Row: Identifiable {
        let conversation: ConversationSummary
        let status: BranchStatus
        var id: Int { conversation.id }
    }

    private static let order = ["conflict", "changes", "missing", "ahead", "behind", "detached", "merged", "clean"]

    private var groups: [(repo: String, rows: [Row])] {
        let rows = engine.conversations.compactMap { conversation in
            engine.branches[conversation.id].map { Row(conversation: conversation, status: $0) }
        }
        return Dictionary(grouping: rows, by: \.status.repo)
            .map { repo, rows in
                (repo: repo, rows: rows.sorted {
                    let a = Self.order.firstIndex(of: $0.status.state) ?? 99, b = Self.order.firstIndex(of: $1.status.state) ?? 99
                    return a != b ? a < b : $0.conversation.updatedAt > $1.conversation.updatedAt
                })
            }
            .sorted { $0.repo.localizedCaseInsensitiveCompare($1.repo) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if groups.isEmpty {
                    Text("No conversation is working in a git repository. Choose a folder in one from a conversation’s tools menu, and its branch shows here and next to it in the sidebar.")
                        .foregroundStyle(.secondary)
                }
                ForEach(groups, id: \.repo) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "shippingbox").foregroundStyle(Theme.tx3)
                            Text(group.repo).font(.headline)
                            Spacer()
                            let worktrees = group.rows.filter { $0.status.managed }.count
                            if worktrees > 0 { Text("\(worktrees) worktree\(worktrees == 1 ? "" : "s")").font(.caption).foregroundStyle(Theme.tx3) }
                        }
                        ForEach(group.rows) { row in rowView(row) }
                    }
                }
                legend
            }
            .padding(.horizontal, 28).padding(.vertical, 22)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.window)
        .navigationTitle("Branches")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") { engine.perform("branches.refresh") }
                    .help("Look at every conversation’s branch again now")
            }
        }
    }

    private var subtitle: String {
        let all = engine.branches.values
        let worktrees = all.filter(\.managed).count
        return "\(all.count) conversation\(all.count == 1 ? "" : "s") in git · \(worktrees) in worktrees of their own"
    }

    private func rowView(_ row: Row) -> some View {
        HStack(spacing: 10) {
            if row.conversation.busy {
                Spinner().frame(width: 20)
            } else {
                AgentAvatar(agent: engine.agent(row.conversation.agentId), size: 20)
            }
            VStack(alignment: .leading, spacing: 3) {
                Button(row.conversation.title.isEmpty ? "New conversation" : row.conversation.title) {
                    model.selection = .conversation(row.conversation.id)
                }
                .buttonStyle(.plain)
                .lineLimit(1)
                HStack(spacing: 6) {
                    BranchIcon(status: row.status, size: 10)
                    Text(row.status.name).font(Theme.mono).lineLimit(1).truncationMode(.middle)
                    Text(row.status.managed ? "· own worktree" : row.status.worktree ? "· worktree" : "· main checkout")
                        .font(.caption).foregroundStyle(Theme.tx3)
                }
                .foregroundStyle(Theme.tx2)
            }
            Spacer(minLength: 8)
            Tag(row.status.stateTitle, row.status.tone).help(row.status.facts.joined(separator: "\n"))
            Menu {
                Button("Open Conversation") { model.selection = .conversation(row.conversation.id) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.status.root)]) }
                    .disabled(row.status.state == "missing")
                Divider()
                if row.status.managed {
                    Button("Remove Worktree…") { WorktreeDialogs.shared.remove(row.conversation.id, status: row.status) }
                } else {
                    Button("New Worktree…") { WorktreeDialogs.shared.create(row.conversation.id, engine: engine) }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(10)
        .panel()
        .help(row.status.help)
    }

    private var legend: some View {
        let entries: [(String, Color, String)] = [
            ("clean", Theme.ok, "Clean and up to date"),
            ("changes", Theme.warn, "Uncommitted changes"),
            ("ahead", Theme.ahead, "Commits not pushed or merged, or behind its upstream"),
            ("merged", Theme.merged, "Its work is merged"),
            ("conflict", Theme.bad, "Conflicts, or a merge or rebase stopped half way"),
            ("other", Theme.tx3, "Detached, or the worktree’s folder is gone"),
        ]
        return VStack(alignment: .leading, spacing: 5) {
            Text("Colours").sectionLabel()
            ForEach(entries, id: \.0) { _, color, text in
                HStack(spacing: 8) {
                    Dot(color: color, size: 8)
                    Text(text).font(.callout).foregroundStyle(Theme.tx2)
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 10, weight: .semibold)).frame(width: 15, height: 15)
                    .overlay(RoundedRectangle(cornerRadius: 3.5).strokeBorder(Theme.tx3, lineWidth: 1.2))
                    .foregroundStyle(Theme.tx3)
                Text("A boxed branch is a worktree; a plain one is the repository’s main checkout.").font(.callout).foregroundStyle(Theme.tx2)
            }
            .padding(.top, 3)
        }
    }
}
