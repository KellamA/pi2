import PiModels
import SwiftUI

/// The board's Branches tab (#478): the branch tracker for this project — the branches and worktrees its conversations
/// work on, and what they left behind.
struct ProjectBranchesTab: View {
    let model: AppModel
    let project: ProjectRow

    var body: some View {
        if project.folder == nil {
            // A project with no folder has its agents work in the shared workspace folder (docs/projects.md, 3.2),
            // which is not a git repository: no branch ever shows here.
            VStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.tx3)
                Text("This project has no folder, so its conversations work in pi²’s shared workspace folder. There are no branches to show.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.tx2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 360)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                BranchesBar(engine: model.engine, project: project)
                BranchTracker(model: model, project: project.id)
            }
            .background(Theme.window)
        }
    }
}

/// The tab's bar: the project's folder and how many of its conversations are in worktrees, with Refresh (#655).
private struct BranchesBar: View {
    let engine: EngineClient
    let project: ProjectRow
    @State private var refreshing = false

    var body: some View {
        WorkListBar(source: summary, icon: "arrow.triangle.branch") {
            Button("Refresh", systemImage: "arrow.clockwise") {
                refreshing = true
                Task {
                    do { _ = try await engine.call("branches.refresh") } catch { engine.lastError = error.localizedDescription }
                    refreshing = false
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.piGhost)
            .controlSize(.small)
            .disabled(refreshing)
            .help("Look at the branches again now")
        }
    }

    /// "3 conversations in git · 1 in a worktree of its own"; the hub's bar names the folder.
    private var summary: String {
        let ids = Set(engine.conversations.filter { $0.projectId == project.id }.map(\.id))
        let rows = engine.branches.filter { ids.contains($0.key) }.values
        let worktrees = rows.filter(\.managed).count
        let own = worktrees == 0 ? "" : " · \(worktrees) in \(worktrees == 1 ? "a worktree of its own" : "worktrees of their own")"
        return "\(rows.count) conversation\(rows.count == 1 ? "" : "s") in git\(own)"
    }
}
