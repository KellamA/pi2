

import SwiftUI

/// pi² for iPhone (docs/iphone.md; how the app is put together: docs/iphone-app.md, "How the app starts"). The keys
/// first, before anything reads one; the store, swept; one `AppSession` for the whole app and the `PhoneLink` that
/// joins it to the paired Mac, started by `Launch`; what the extensions show kept in step with it (`PhoneSurfaces`);
/// the session registered for Shortcuts; and one navigation root, `RootView`.
@main
struct Pi2App: App {
    @State private var session: AppSession
    @State private var link: PhoneLink
    @State private var surfaces: PhoneSurfaces

    init() {
        // Clears an earlier installation's Keychain items at the first launch: before anything reads a key (3.2).
        let keyring = PhoneKeyring.live()
        let store = PhoneStore()
        let swept = store.sweep()
        let session = AppSession()
        let link = PhoneLink(session: session, keyring: keyring, store: store)
        let surfaces = PhoneSurfaces(link: link)
        surfaces.swept(swept)
        link.onEnded = { [surfaces] _ in surfaces.forgetTheMac() }
        Launch.start(link)
        // App Intents run in this process, which iOS may start for one with no scene: they use this session, and open
        // pi² for Face ID first while no session Face ID opened is open (#701).
        IntentSessions.register(session, isOpen: { [link] in link.isOpenForIntents })
        _session = State(initialValue: session)
        _link = State(initialValue: link)
        _surfaces = State(initialValue: surfaces)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(link)
                .environment(surfaces)
        }
    }
}
