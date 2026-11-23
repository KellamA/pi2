import SwiftUI

/// Usage and limits on a page: the plan's windows and today's spending (docs/design/iphone.md, "Every screen and
/// function of the Mac app"). #697 builds it: replace this body, keep the type and its initialiser, and add files beside
/// it in `Usage/`.
struct UsageView: View {
    init() {}

    var body: some View {
        FeaturePlaceholder(screen: "Usage and limits", issue: 697)
    }
}
