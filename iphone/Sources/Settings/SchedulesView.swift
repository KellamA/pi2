import SwiftUI

/// The schedules, as the Mac has them, from More on the projects list (docs/design/iphone.md, "Every screen and function
/// of the Mac app"). #697 builds it: replace this body, keep the type and its initialiser, and add files beside it in
/// `Settings/`.
struct SchedulesView: View {
    init() {}

    var body: some View {
        FeaturePlaceholder(screen: "Schedules", issue: 697)
    }
}
