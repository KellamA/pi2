import SwiftUI

/// pi² for iPhone (docs/iphone.md; how the app is put together: docs/iphone-app.md). One `AppSession` for the whole
/// app, started by `Launch`, and one navigation root, `RootView`.
@main
struct Pi2App: App {
    @State private var session: AppSession

    init() {
        let session = AppSession()
        Launch.start(session)
        _session = State(initialValue: session)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
        }
    }
}
