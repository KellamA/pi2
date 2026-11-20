import SwiftUI

/// The board's Branches tab (#478): the branch tracker for this project alone — the branches and worktrees its
/// conversations work on, with the same rows and actions as the Branches page, which shows every conversation's.
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
            BranchTracker(model: model, project: project.id)
                .background(Theme.window)
        }
    }
}
