import SwiftUI

/// The way into the demo mode, which the first screen shows under pairing: **Try it without a Mac** (docs/iphone.md 9.4;
/// docs/design/iphone.md, "The demo mode"; the drafts' figure 2). It starts the demo (`Launch.start(session, demo: true)`),
/// and the app goes to the projects list, with the Demo bar on top.
struct DemoEntry: View {
    @Environment(AppSession.self) private var session: AppSession?

    init() {}

    var body: some View {
        VStack(spacing: 6) {
            Button("Try it without a Mac") {
                if let session { Launch.start(session, demo: true) }
            }
            .font(.body.weight(.semibold))
            .buttonStyle(.borderless)
            .accessibilityHint("Opens pi² on demo projects. Nothing connects anywhere, and nothing you do there leaves this iPhone.")
            Text("Demo projects with agents at work, cards to answer and a conversation that answers back, with no Mac and no network.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview("Try it without a Mac") {
    DemoEntry()
        .padding()
        .environment(AppSession())
}
