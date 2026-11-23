
import PiModels
import SwiftUI
import UIKit

extension BranchStatus {
    /// The state's colour, as the Mac's tracker draws it (`BranchStatus.color`), in the system's colours.
    var boardColor: Color {
        switch state {
        case "conflict": .red
        case "changes": .orange
        case "ahead", "behind": .blue
        case "merged": .purple
        case "clean": .green
        default: .secondary
        }
    }
}

/// The Branches page (the Mac's Branches tab, app/Sources/pi2/ProjectBranchesTab.swift and BranchViews.swift): the
/// branches and worktrees the project's conversations work on, grouped by repository, the worktrees left behind by
/// conversations archived or deleted, and what the colours mean. A conversation moves into a worktree of its own, or
/// leaves one, from its row.
struct BoardBranchesPage: View {
    let project: ProjectRow
    let data: BoardData

    @Environment(AppSession.self) private var session
    @Environment(\.openRoute) private var openRoute
    @State private var problem: String?
    @State private var notice: String?
    @State private var creating: BoardWorktreeAsk?
    @State private var removing: BoardWorktreeRemoval?
    @State private var refreshing = false

    var body: some View {
        Group {
            if project.folder == nil {
                ContentUnavailableView("No branches", systemImage: "arrow.triangle.branch", description: Text(
                    "This project has no folder, so its conversations work in pi²’s shared workspace folder. There are no branches to show."))
            } else {
                list
            }
        }
        .alert("New worktree", isPresented: Binding(get: { creating != nil }, set: { if !$0 { creating = nil } })) {
            TextField("Branch", text: Binding(get: { creating?.branch ?? "" }, set: { creating?.branch = $0 }))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Create") { create() }
            Button("Cancel", role: .cancel) { creating = nil }
        } message: {
            Text("The conversation moves into a checkout of its own on this branch, made from where its folder is now. Other agents can keep working in the repository meanwhile. An existing branch is checked out as it is.")
        }
        .confirmationDialog(removing.map { "Remove the worktree for \($0.status.branch ?? "this conversation")?" } ?? "",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { removal in
            if removal.status.isDirty {
                Button("Remove and Discard Changes", role: .destructive) { remove(removal, force: true, deleteBranch: false) }
            } else {
                Button("Remove Worktree, Keep Branch") { remove(removal, force: false, deleteBranch: false) }
                Button("Remove Worktree and Branch", role: .destructive) { remove(removal, force: false, deleteBranch: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { removal in
            Text(removal.status.isDirty
                ? "It has \(removal.status.changes + removal.status.conflicts) uncommitted changes, which would be lost. Commit them first to keep them. The branch is kept. Your Mac is told of the change."
                : "The conversation goes back to the folder it worked in before. A branch is deleted only when everything on it is on what it was made from or on the default branch, and no other worktree has it checked out. Your Mac is told of the change.")
        }
        .alert("Worktree removed", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK") { notice = nil }
        } message: {
            Text(notice ?? "")
        }
    }

    private var list: some View {
        let groups = data.branchGroups(project.id)
        let leftBehind = data.leftBehind(project.id)
        return ScrollViewReader { scroller in
            List {
                if let sample = data.sample { BoardSampleNote(what: sample) }
                Section {
                    Label(data.branchSummary(project.id), systemImage: "arrow.triangle.branch")
                        .foregroundStyle(.secondary)
                    if let problem { BoardProblem(problem) }
                }
                if groups.isEmpty && leftBehind.isEmpty {
                    Section {
                        Text("None of this project’s conversations is working in a git repository.").foregroundStyle(.secondary)
                    }
                }
                ForEach(groups) { group in
                    Section {
                        ForEach(group.rows) { row in
                            conversationRow(row)
                        }
                    } header: {
                        let count = group.worktrees > 0 ? "\(group.worktrees) worktree\(group.worktrees == 1 ? "" : "s")" : nil
                        // The count goes under the repository's name when both do not fit on one line, rather than
                        // breaking the name.
                        ViewThatFits(in: .horizontal) {
                            HStack {
                                Label(group.repo, systemImage: "shippingbox").fixedSize()
                                Spacer()
                                if let count { Text(count).fixedSize() }
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.repo)
                                if let count { Text(count) }
                            }
                        }
                    }
                }
                if !leftBehind.isEmpty {
                    Section {
                        ForEach(leftBehind) { item in leftBehindRow(item) }
                    } header: {
                        Text("Left behind · \(leftBehind.count) worktree\(leftBehind.count == 1 ? "" : "s")")
                    } footer: {
                        Text("Worktrees of conversations that were archived or deleted. They stay on your Mac, with any work in them, until you remove them. Removing one keeps its branch unless you choose otherwise.")
                    }
                    .id("left-behind")
                }
                legend.id("legend")
            }
            .listStyle(.insetGrouped)
            #if DEBUG
            .task { await BoardDebugAct.branches(self, data: data, scroller: scroller) }
            #endif
        }
        .refreshable { await refresh() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }
                    .disabled(refreshing || !data.connected)
            }
        }
    }

    // MARK: - Rows

    private func conversationRow(_ row: BoardBranchRow) -> some View {
        let title = row.conversation.title.isEmpty ? "New conversation" : row.conversation.title
        return Button {
            openRoute(.conversation(row.conversation.id))
        } label: {
            HStack(alignment: .top, spacing: 10) {
                if row.conversation.busy {
                    ProgressView().frame(width: 24)
                } else {
                    AgentMark(agent: data.agent(row.conversation.agentId), size: 24)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).foregroundStyle(.primary).lineLimit(2)
                    branchLine(row.status, shared: row.sharing != nil)
                    Text(row.status.boardKind(shared: row.sharing != nil)).font(.caption).foregroundStyle(.secondary)
                    stateLine(row.status)
                }
            }
            .padding(.leading, row.nested ? 18 : 0)
        }
        // The row's words in the text's colours, not the tint a button takes.
        .foregroundStyle(.primary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(row.status.worktree ? "worktree" : "branch") \(row.status.boardName), \(row.status.boardStateTitle)")
        .accessibilityValue(([row.status.boardKind(shared: row.sharing != nil)] + row.status.boardFacts).joined(separator: ". "))
        .accessibilityHint("Opens the conversation")
        .contextMenu { actions(conversation: row.conversation.id, status: row.status) }
        .swipeActions {
            if row.status.managed {
                Button("Remove Worktree", role: .destructive) { removing = BoardWorktreeRemoval(conversation: row.conversation.id, status: row.status) }
            } else {
                Button("New Worktree") { ask(row.conversation.id) }.tint(.pi2Accent)
            }
        }
        .accessibilityActions { actions(conversation: row.conversation.id, status: row.status) }
    }

    @ViewBuilder
    private func actions(conversation: Int, status: BranchStatus) -> some View {
        if status.managed {
            Button("Remove Worktree…", systemImage: "trash", role: .destructive) { removing = BoardWorktreeRemoval(conversation: conversation, status: status) }
                .disabled(!data.connected)
        } else {
            Button("New Worktree…", systemImage: "plus.square.on.square") { ask(conversation) }
                .disabled(!data.connected)
        }
        if let branch = status.branch {
            Button("Copy Branch Name", systemImage: "doc.on.doc") { UIPasteboard.general.string = branch }
        }
    }

    private func leftBehindRow(_ item: LeftBehindWorktree) -> some View {
        let archived = item.reason == "archived"
        let title = item.title.isEmpty ? "New conversation" : item.title
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: archived ? "archivebox" : "trash")
                .foregroundStyle(.secondary).frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).lineLimit(2)
                branchLine(item.status, shared: false)
                Text("\(item.status.repo) · \(archived ? "archived" : "deleted")").font(.caption).foregroundStyle(.secondary)
                stateLine(item.status)
                Button("Remove…") { removing = BoardWorktreeRemoval(conversation: item.id, status: item.status) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!data.connected)
                    .accessibilityHint("Removes this worktree’s folder; you can keep or delete its branch")
            }
        }
        .accessibilityElement(children: .combine)
        .contextMenu {
            if archived { Button("Open Conversation", systemImage: "bubble.left") { openRoute(.conversation(item.id)) } }
            if let branch = item.status.branch {
                Button("Copy Branch Name", systemImage: "doc.on.doc") { UIPasteboard.general.string = branch }
            }
        }
    }

    /// The branch's mark (boxed for a worktree, faded for a sub-chat in its parent's checkout) and its name.
    private func branchLine(_ status: BranchStatus, shared: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.caption.weight(shared ? .regular : .semibold))
                .foregroundStyle(status.boardColor)
                .padding(2)
                .overlay {
                    if status.worktree { RoundedRectangle(cornerRadius: 3).strokeBorder(status.boardColor, lineWidth: 1) }
                }
                .opacity(shared ? 0.5 : 1)
                .accessibilityHidden(true)
            Text(status.boardName).font(.subheadline.monospaced()).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
        }
    }

    /// How the branch stands, in a coloured word, with the size of its change.
    private func stateLine(_ status: BranchStatus) -> some View {
        HStack(spacing: 8) {
            BoardTag(status.boardStateTitle, color: status.boardColor)
            if (status.added ?? 0) + (status.removed ?? 0) > 0 {
                Text("+\(status.added ?? 0)").foregroundStyle(.green)
                Text("−\(status.removed ?? 0)").foregroundStyle(.red)
            }
        }
        .font(.caption.monospacedDigit())
    }

    private var legend: some View {
        let entries: [(String, Color, String)] = [
            ("clean", .green, "Clean and up to date"),
            ("changes", .orange, "Uncommitted changes"),
            ("ahead", .blue, "Commits not pushed or merged, or behind its upstream"),
            ("merged", .purple, "Its work is merged"),
            ("conflict", .red, "Conflicts, or a merge or rebase stopped half way"),
            ("other", .secondary, "Detached, or the worktree’s folder is gone"),
        ]
        return Section("Colours") {
            ForEach(entries, id: \.0) { _, color, text in
                Label {
                    Text(text)
                } icon: {
                    Image(systemName: "circle.fill").foregroundStyle(color).font(.caption)
                }
            }
            Text("A boxed branch is a worktree; a plain one is the repository’s main checkout. A faded one is a sub-chat working in its parent’s checkout.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    // MARK: - Requests

    private func refresh() async {
        refreshing = true
        problem = await BoardRequests.refreshBranches(session.engine).map { "Not looked at again: \($0)" }
        refreshing = false
    }

    func ask(_ conversation: Int) {
        creating = BoardWorktreeAsk(conversation: conversation, branch: "")
        let engine = session.engine
        Task {
            if let suggested = await BoardRequests.suggestBranch(engine, conversation: conversation),
               creating?.conversation == conversation, creating?.branch == "" {
                creating?.branch = suggested
            }
        }
    }

    private func create() {
        guard let ask = creating else { return }
        creating = nil
        let engine = session.engine
        boardSend($problem) {
            await BoardRequests.createWorktree(engine, conversation: ask.conversation, branch: ask.branch).map { "No worktree was made: \($0)" }
        }
    }

    private func remove(_ removal: BoardWorktreeRemoval, force: Bool, deleteBranch: Bool) {
        removing = nil
        let engine = session.engine
        Task {
            switch await BoardRequests.removeWorktree(engine, conversation: removal.conversation, force: force, deleteBranch: deleteBranch) {
            case .success(let note): problem = nil; notice = note
            case .failure(let failure): problem = "The worktree was not removed: \(failure.message)"
            }
        }
    }

    #if DEBUG
    func debugRemove(_ conversation: Int, status: BranchStatus) { removing = BoardWorktreeRemoval(conversation: conversation, status: status) }
    #endif
}

/// The branch name asked for a conversation's new worktree.
struct BoardWorktreeAsk: Equatable {
    let conversation: Int
    var branch: String
}

/// The worktree whose removal is being confirmed.
struct BoardWorktreeRemoval: Equatable {
    let conversation: Int
    let status: BranchStatus
}
