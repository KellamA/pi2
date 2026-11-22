import SwiftUI

/// The way into the demo mode, which the first screen shows under pairing: **Try it without a Mac** (docs/iphone.md 9.4;
/// docs/design/iphone.md, "The demo mode"). #684 builds it: replace this body, keep the type and its initialiser, and add
/// `DemoTransport` and the rest beside it in `Demo/`. The transport it starts is chosen in `App/Launch.swift`.
struct DemoEntry: View {
    init() {}

    var body: some View {
        FeaturePlaceholder(screen: "Try it without a Mac", issue: 684)
    }
}
