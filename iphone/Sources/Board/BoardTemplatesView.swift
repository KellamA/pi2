import SwiftUI

/// The templates, listed and edited as agents, from More on the projects list (docs/design/iphone.md, "Every screen and
/// function of the Mac app"). #696 builds it: replace this body, keep the type and its initialiser, and add files beside
/// it in `Board/`. A template's page opens with `openRoute(.agent(id))`.
struct BoardTemplatesView: View {
    init() {}

    var body: some View {
        FeaturePlaceholder(screen: "Templates", issue: 696)
    }
}
