import SwiftUI

/// A new project, from a folder the Mac offers (its projects' folders, recent folders), since the phone cannot browse
/// the Mac's disk (docs/design/iphone.md, "What stays on the Mac, and why"). #698 builds it: replace this body, keep the
/// type and its initialiser, and add files beside it in `Conversations/`.
struct NewProjectView: View {
    init() {}

    var body: some View {
        FeaturePlaceholder(screen: "New project", issue: 698)
    }
}
