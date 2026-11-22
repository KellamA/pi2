import SwiftUI

/// The projects list, the app's root once a Mac is paired or the demo is on: Needs you at the top, the Dashboard, the
/// projects, chats and the archive, under the connection bar (docs/design/iphone.md, "The projects list"). #685 builds
/// it: replace this body, keep the type and its initialiser, and add files beside it in `Home/`.
struct HomeView: View {
    init() {}

    var body: some View {
        FeaturePlaceholder(screen: "Projects", issue: 685)
    }
}
