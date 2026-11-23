import SwiftUI

/// The app's settings a phone may change, from More on the projects list: what the Mac's Settings shows that is not a
/// secret, a sign-in or the Mac's upkeep (docs/design/iphone.md, "Every screen and function of the Mac app" and "What
/// stays on the Mac, and why"). #697 builds it: replace this body, keep the type and its initialiser, and add files
/// beside it in `Settings/`.
struct SettingsView: View {
    init() {}

    var body: some View {
        FeaturePlaceholder(screen: "Settings", issue: 697)
    }
}
