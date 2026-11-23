import SwiftUI

/// The archive, as the Mac has it, from the projects list (docs/design/iphone.md, "Every screen and function of the Mac
/// app"). #698 builds it: replace this body, keep the type and its initialiser, and add files beside it in
/// `Conversations/`.
struct ArchiveView: View {
    init() {}

    var body: some View {
        FeaturePlaceholder(screen: "Archive", issue: 698)
    }
}
