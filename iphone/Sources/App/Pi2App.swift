import SwiftUI

/// pi² for iPhone (docs/iphone.md). For now the app is its first screen, as for a phone not yet paired with a Mac:
/// pairing, the keys and the channel come with the rest of #680.
@main
struct Pi2App: App {
    var body: some Scene {
        WindowGroup {
            FirstScreen()
        }
    }
}
