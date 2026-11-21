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
        default: Theme.tx3 // missing, unavailable, detached
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
        if state == "unavailable" { return ["The checkout could not be read. Use Remove to retry an interrupted removal."] }
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

    /// `sharing`: whose checkout this one, a sub-chat, works in (see `EngineClient.sharing`).
    func whereText(sharing: CheckoutSharing?) -> String {
        if managed { return "Its own worktree of \(repo)" }
        switch sharing {
        case .worktree(let owner): return "Works in the worktree of “\(owner.displayTitle)”"
        case .checkout(let parent):
            return "Works in the same \(worktree ? "worktree" : "main checkout") of \(repo) as “\(parent.displayTitle)”"
        case nil: return worktree ? "A worktree of \(repo)" : "The main checkout of \(repo)"
        }
    }

    /// The checkout in a few words, after the branch's name.
    func kindText(sharing: CheckoutSharing?) -> String {
        if managed { return "· own worktree" }
        switch sharing {
        case .worktree: return "· parent’s worktree"
        case .checkout: return worktree ? "· parent’s worktree" : "· parent’s checkout"
        case nil: return worktree ? "· worktree" : "· main checkout"
        }
    }

    func help(sharing: CheckoutSharing?) -> String { ([name, whereText(sharing: sharing)] + facts).joined(separator: "\n") }

    /// Whether there is a change to size: lines added or removed (#598).
    var hasChangeSize: Bool { (added ?? 0) + (removed ?? 0) > 0 }

    /// What the two numbers count, in words.
    var changeSizeHelp: String {
        let added = added ?? 0, removed = removed ?? 0
        let lines = "\(added) line\(added == 1 ? "" : "s") added and \(removed) removed"
        if let base { return "\(lines): what is committed on \(name) since it left \(base), and what is not committed yet" }
        return "\(lines) that are not committed yet"
    }

    /// The repository's main checkout on its default branch: the tracker measures against no other branch there (`base`
    /// is nil only on the branch it would measure against). Said of a working agent's row, where it is worth a warning:
    /// what the agent changes lands where the person and every other agent work (#596, #598).
    var onDefaultBranchInMainCheckout: Bool { !worktree && branch != nil && base == nil && state != "missing" }
}

/// The size of a conversation's change, "+128 −14", in a diff's colours (#598). Nothing when nothing changed, or the
/// tracker could not measure it.
struct ChangeSize: View {
    let status: BranchStatus
    var size: CGFloat = 10.5

    var body: some View {
        if status.hasChangeSize {
            let added = status.added ?? 0, removed = status.removed ?? 0
            HStack(spacing: 4) {
                Text("+\(Self.short(added))").foregroundStyle(Theme.ok)
                Text("−\(Self.short(removed))").foregroundStyle(Theme.bad)
            }
            .font(.system(size: size, weight: .medium).monospacedDigit())
            .lineLimit(1)
            .fixedSize()
            .help(status.changeSizeHelp)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(added) lines added, \(removed) removed")
        }
    }

    /// A count in four characters at most, so that a vast change does not take the row: 12345 is "12k".
    static func short(_ count: Int) -> String {
        switch count {
        case ..<10_000: "\(count)"
        case ..<1_000_000: "\(count / 1000)k"
        default: "\(count / 1_000_000)M"
        }
    }
}

/// The quiet second line of a conversation's row under a project in the sidebar (#598): the branch it works on, with the
/// old sidebar's mark and help (`BranchIcon`, boxed for a worktree, faded for a sub-chat in its parent's checkout), and
/// the size of its change. A view of its own, so that the tracker's event draws this line again and not the row.
/// `working`: a working agent's row, which says so, quietly, when the agent works in the main checkout on its default branch.
struct BranchLine: View {
    let engine: EngineClient
    let conversationID: Int
    var working = false

    var body: some View {
        if let status = engine.branches[conversationID] {
            let sharing = engine.sharing(of: conversationID)
            HStack(spacing: 5) {
                BranchIcon(status: status, size: 9, shared: sharing != nil)
                    .help(status.help(sharing: sharing))
                Text(status.name)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.tx3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(status.help(sharing: sharing))
                    .layoutPriority(1)
                if working, status.onDefaultBranchInMainCheckout {
                    // The words give way to the mark alone, before the branch's name does; the help says it either way.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 3) {
                            Text(status.kindText(sharing: sharing))
                            Image(systemName: "exclamationmark.triangle")
                        }
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.warn)
                    .lineLimit(1)
                    .help("Works in \(status.repo)’s main checkout, on its default branch \(status.name), not in a worktree of its own: what it changes lands where you and the other agents work.")
                    .accessibilityLabel("Works in the main checkout on \(status.name)")
                }
                Spacer(minLength: 4)
                ChangeSize(status: status)
            }
        }
    }
}

/// A sub-chat working in a checkout that is not its own, as most do: the one the conversation that opened it works in.
enum CheckoutSharing {
    /// The worktree pi² made for a conversation further up (docs/worktrees.md, Sub-chats).
    case worktree(owner: ConversationSummary)
    /// Any other checkout its parent works in: the repository's main checkout, or a worktree pi² did not make.
    case checkout(parent: ConversationSummary)
}

extension ConversationSummary {
    var displayTitle: String { title.isEmpty ? "New conversation" : title }
}

extension EngineClient {
    /// For a sub-chat working in the worktree pi² made for a conversation further up (docs/worktrees.md, Sub-chats):
    /// that conversation. Nil for any other conversation. Worked out from the parents' checkouts, as the sidebar does.
    func worktreeOwner(of id: Int) -> ConversationSummary? {
        guard let status = branches[id], status.worktree, !status.managed else { return nil }
        var seen: Set<Int> = [id]
        var parentID = conversations.first { $0.id == id }?.parent
        while let next = parentID, seen.insert(next).inserted, let parent = conversations.first(where: { $0.id == next }),
              let parentStatus = branches[next], parentStatus.root == status.root {
            if parentStatus.managed { return parent }
            parentID = parent.parent
        }
        return nil
    }

    /// For a sub-chat working in the same checkout as the conversation that opened it, or in a worktree pi² made for one
    /// further up: whose it is. Nil for a conversation in a checkout of its own, which is every one that is not a sub-chat.
    func sharing(of id: Int) -> CheckoutSharing? {
        if let owner = worktreeOwner(of: id) { return .worktree(owner: owner) }
        guard let status = branches[id], !status.managed,
              let parentID = conversations.first(where: { $0.id == id })?.parent,
              let parent = conversations.first(where: { $0.id == parentID }),
              branches[parentID]?.root == status.root else { return nil }
        return .checkout(parent: parent)
    }
}

/// The branch icon: a plain branch for a repository's main checkout, a boxed one for a worktree. `shared` draws it
/// faded and lighter, for a sub-chat working in its parent's checkout rather than one of its own. It keeps the colour of
/// how the branch stands, which is what the sidebar shows it for; fading, rather than another shape, leaves plain and
/// boxed meaning the same thing everywhere, and lets a sub-chat on a branch of its own stand out among its siblings.
struct BranchIcon: View {
    let status: BranchStatus
    var size: CGFloat = 11
    var shared = false

    static let sharedOpacity = 0.5

    var body: some View {
        Image(systemName: "arrow.triangle.branch")
            .font(.system(size: status.worktree ? size - 2.5 : size, weight: shared ? .regular : .semibold))
            .foregroundStyle(status.color)
            .frame(width: size + 4, height: size + 4)
            .overlay {
                if status.worktree {
                    RoundedRectangle(cornerRadius: 3.5).strokeBorder(status.color.opacity(0.85), lineWidth: shared ? 1 : 1.2)
                }
            }
            .opacity(shared ? Self.sharedOpacity : 1)
            .accessibilityLabel("\(status.worktree ? "Worktree" : "Branch") \(status.name), \(status.stateTitle)\(shared ? ", in its parent’s checkout" : "")")
    }
}

/// The icon on a conversation's row in the sidebar; clicking it shows the details.
struct BranchBadge: View {
    let engine: EngineClient
    let conversationID: Int
    let status: BranchStatus
    @State private var showing = false

    var body: some View {
        let sharing = engine.sharing(of: conversationID)
        Button { showing.toggle() } label: {
            BranchIcon(status: status, shared: sharing != nil).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(status.help(sharing: sharing))
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
        let sharing = engine.sharing(of: conversationID)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                BranchIcon(status: status, size: 13, shared: sharing != nil)
                Text(status.name).font(.system(size: 13, weight: .semibold, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Tag(status.stateTitle, status.tone)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(status.whereText(sharing: sharing)).foregroundStyle(Theme.tx2)
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
                    Button("Copy Name") {
                        AppCopy.write(branch, kind: .branchName, engine: engine, conversation: conversationID)
                    }.help("Copy the branch name")
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
        let sharing = engine.sharing(of: id)
        Menu {
            Text(status.whereText(sharing: sharing))
            ForEach(status.facts, id: \.self) { Text($0) }
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: status.root)]) }
                .disabled(status.state == "missing")
            if let branch = status.branch {
                Button("Copy Branch Name") {
                    AppCopy.write(branch, kind: .branchName, engine: engine, conversation: id)
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
                BranchIcon(status: status, shared: sharing != nil)
                Text(status.branch ?? status.head ?? "detached").lineLimit(1).truncationMode(.middle).frame(maxWidth: 170)
            }
        }
        .help(status.help(sharing: sharing))
    }
}

// MARK: - Making and removing a worktree

/// The questions asked before making or removing a worktree. Held here, not in a view, so the sidebar, the toolbar
/// and the Branches page can all ask, and one place shows the dialog (see `worktreeDialogs`).
@MainActor
@Observable
final class WorktreeDialogs {
    static let shared = WorktreeDialogs()

    /// `subChat`: said when the conversation is a sub-chat working in its parent's checkout.
    struct Creating: Equatable { let id: Int; var branch: String; var subChat: String? }
    struct Removing: Equatable { let id: Int; let status: BranchStatus }

    var creating: Creating?
    var removing: Removing?
    /// Said after a worktree was removed but its branch kept.
    var notice: String?

    func create(_ id: Int, engine: EngineClient) {
        var subChat: String?
        if engine.sharing(of: id) != nil, let status = engine.branches[id] {
            let checkout = status.worktree ? "worktree" : "checkout"
            let start = status.branch.map { "the parent’s branch \($0)" } ?? "the commit the parent’s \(checkout) is on"
            subChat = "The new worktree starts from \(start), and this sub-chat stops working in its parent’s \(checkout)."
        }
        creating = Creating(id: id, branch: "", subChat: subChat)
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
                Text("The conversation moves into a checkout of its own on this branch, made from where its folder is now. Other agents can keep working in the repository meanwhile. An existing branch is checked out as it is."
                    + (dialogs.creating?.subChat.map { "\n\n\($0)" } ?? ""))
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
/// of its own, and how the branch stands. The page shows every conversation's; the board's Branches tab (#478) shows
/// only one project's, which is what `BranchTracker.project` picks.
struct BranchesView: View {
    @Bindable var model: AppModel
    private var engine: EngineClient { model.engine }

    var body: some View {
        BranchTracker(model: model, project: nil)
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
}

/// The branch tracker's list itself: the rows grouped by repository, the worktrees left behind, and the colour legend.
/// `project` is nil for every conversation's branches, or a project's id for only its conversations' (#478).
struct BranchTracker: View {
    @Bindable var model: AppModel
    let project: String?
    private var engine: EngineClient { model.engine }

    private struct Row: Identifiable {
        let conversation: ConversationSummary
        let status: BranchStatus
        /// For a sub-chat in its parent's checkout: whose it is.
        let sharing: CheckoutSharing?
        /// Listed under the conversation whose checkout it shares, and indented.
        var nested = false
        var id: Int { conversation.id }
        /// For a sub-chat in its parent's checkout, the conversation it is listed under: the one its worktree was made
        /// for, or the parent whose main checkout (or worktree pi² did not make) it works in.
        var listedUnder: ConversationSummary? {
            switch sharing {
            case .worktree(let owner): owner
            case .checkout(let parent): parent
            case nil: nil
            }
        }
    }

    private static let order = ["conflict", "changes", "missing", "unavailable", "ahead", "behind", "detached", "merged", "clean"]

    /// The conversations whose branches show: every one's, or only the project's.
    private var include: (ConversationSummary) -> Bool {
        project == nil ? { _ in true } : { $0.projectId == project }
    }

    /// Worktrees whose conversations were archived or deleted. On a project's tab, only those of conversations
    /// archived in that project: one whose conversation was deleted can no longer be told apart, and stays on the page.
    private var leftBehind: [LeftBehindWorktree] {
        guard let project else { return engine.leftBehind }
        return engine.leftBehind.filter { item in
            item.reason == "archived" && engine.archived.first(where: { $0.id == item.id })?.projectId == project
        }
    }

    private var groups: [(repo: String, rows: [Row])] {
        let rows: [Row] = engine.conversations.compactMap { conversation in
            guard include(conversation), let status = engine.branches[conversation.id] else { return nil }
            return Row(conversation: conversation, status: status, sharing: engine.sharing(of: conversation.id))
        }
        return Dictionary(grouping: rows, by: \.status.repo)
            .map { repo, rows in
                let sorted = rows.sorted {
                    let a = Self.order.firstIndex(of: $0.status.state) ?? 99, b = Self.order.firstIndex(of: $1.status.state) ?? 99
                    return a != b ? a < b : $0.conversation.updatedAt > $1.conversation.updatedAt
                }
                // Sub-chats in their parent's checkout follow the conversation whose checkout it is, oldest first, as in
                // the sidebar: under the one a worktree was made for, or under the parent whose main checkout they share.
                // That conversation has the same checkout, so it is in this repository's rows too; should it not be, the
                // sub-chat is listed on its own rather than not at all.
                let tops = Set(sorted.filter { $0.listedUnder == nil }.map(\.id))
                let isNested = { (row: Row) in row.listedUnder.map { tops.contains($0.id) } ?? false }
                let under = Dictionary(grouping: sorted.filter(isNested), by: { $0.listedUnder!.id })
                return (repo: repo, rows: sorted.filter { !isNested($0) }.flatMap { row in
                    [row] + (under[row.id] ?? [])
                        .sorted { ($0.conversation.createdAt ?? 0) < ($1.conversation.createdAt ?? 0) }
                        .map { var nested = $0; nested.nested = true; return nested }
                })
            }
            .sorted { $0.repo.localizedCaseInsensitiveCompare($1.repo) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if groups.isEmpty && leftBehind.isEmpty {
                    Text(project == nil
                        ? "No conversation is working in a git repository. Choose a folder in one from a conversation’s tools menu, and its branch shows here and next to it in the sidebar."
                        : "None of this project’s conversations is working in a git repository.")
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
                        ForEach(group.rows) { row in rowView(row).padding(.leading, row.nested ? 16 : 0) }
                    }
                }
                if !leftBehind.isEmpty { leftBehindSection }
                legend
            }
            .padding(.horizontal, 28).padding(.vertical, 22)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func rowView(_ row: Row) -> some View {
        HStack(spacing: 10) {
            if let wait = engine.limitWaits[row.conversation.id] {
                Image(systemName: "hourglass").foregroundStyle(Theme.warn).frame(width: 20).help(wait.sentence)
            } else if row.conversation.busy {
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
                    BranchIcon(status: row.status, size: 10, shared: row.sharing != nil)
                    Text(row.status.name).font(Theme.mono).lineLimit(1).truncationMode(.middle)
                    Text(row.status.kindText(sharing: row.sharing))
                        .font(.caption).foregroundStyle(Theme.tx3)
                }
                .foregroundStyle(Theme.tx2)
            }
            Spacer(minLength: 8)
            ChangeSize(status: row.status, size: 11.5)
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
        .help(row.status.help(sharing: row.sharing))
    }

    /// Worktrees whose conversations were archived or deleted. They stay on disk, with any work in them, until removed.
    private var leftBehindSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "tray").foregroundStyle(Theme.tx3)
                Text("Left Behind").font(.headline)
                Spacer()
                // The rows listed here, which on a project's tab are fewer than every left-behind worktree (#478).
                let count = leftBehind.count
                Text("\(count) worktree\(count == 1 ? "" : "s")").font(.caption).foregroundStyle(Theme.tx3)
            }
            Text("Worktrees of conversations that were archived or deleted. They stay on disk, with any work in them, until you remove them. Removing one keeps its branch unless you choose otherwise.")
                .font(.callout).foregroundStyle(Theme.tx2)
            ForEach(leftBehind) { item in leftBehindRow(item) }
        }
    }

    private func leftBehindRow(_ item: LeftBehindWorktree) -> some View {
        let archived = item.reason == "archived"
        let title = item.title.isEmpty ? "New conversation" : item.title
        return HStack(spacing: 10) {
            Image(systemName: archived ? "archivebox" : "trash")
                .foregroundStyle(Theme.tx3)
                .frame(width: 20)
                .help(archived ? "Its conversation is in the Archive" : "Its conversation was deleted")
            VStack(alignment: .leading, spacing: 3) {
                if archived {
                    Button(title) { model.selection = .conversation(item.id) }
                        .buttonStyle(.plain)
                        .lineLimit(1)
                } else {
                    Text(title).lineLimit(1).foregroundStyle(Theme.tx2)
                }
                HStack(spacing: 6) {
                    BranchIcon(status: item.status, size: 10)
                    Text(item.status.name).font(Theme.mono).lineLimit(1).truncationMode(.middle)
                    Text("· \(item.status.repo) · \(archived ? "archived" : "deleted")").font(.caption).foregroundStyle(Theme.tx3)
                }
                .foregroundStyle(Theme.tx2)
            }
            Spacer(minLength: 8)
            ChangeSize(status: item.status, size: 11.5)
            Tag(item.status.stateTitle, item.status.tone).help(item.status.facts.joined(separator: "\n"))
            Button("Remove…") { WorktreeDialogs.shared.remove(item.id, status: item.status) }
                .buttonStyle(.piSecondary)
                .help("Remove this worktree’s folder; you can keep or delete its branch")
            Menu {
                if archived { Button("Open Conversation") { model.selection = .conversation(item.id) } }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.status.root)]) }
                    .disabled(item.status.state == "missing")
                if let branch = item.status.branch {
                    Button("Copy Branch Name") {
                        AppCopy.write(branch, kind: .branchName, engine: engine, conversation: item.id)
                    }
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
        .help(([item.status.name, item.status.root] + item.status.facts).joined(separator: "\n"))
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
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 10, weight: .regular)).frame(width: 15, height: 15)
                    .foregroundStyle(Theme.tx2)
                    .opacity(BranchIcon.sharedOpacity)
                Text("A faded one is a sub-chat working in its parent’s checkout rather than one of its own.").font(.callout).foregroundStyle(Theme.tx2)
            }
            HStack(spacing: 8) {
                HStack(spacing: 3) {
                    Text("+").foregroundStyle(Theme.ok)
                    Text("−").foregroundStyle(Theme.bad)
                }
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .frame(width: 15)
                Text("Lines added and removed: what is committed on the branch since it left the one it was made from, and what is not committed yet.").font(.callout).foregroundStyle(Theme.tx2)
            }
        }
    }
}
