
#if DEBUG
import Foundation
import os
import RemoteKit

/// A debug build's way to hand the pairing screens a code, since the simulator has no camera (docs/iphone.md 10): the
/// payload's text in `PI2_PAIR` (`scripts/iphone-sim run … --env PI2_PAIR='pi2://pair?…'`), taken as if scanned, by
/// RemoteKit's reader like any code. Not compiled into a release build, which takes a code from its camera alone and
/// registers no `pi2:` scheme (3.1).
enum PairingDebugLaunch {
    static var payload: String? {
        ProcessInfo.processInfo.environment["PI2_PAIR"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Says the six digits in the log, in the simulator, as the flow puts them on screen, and only for the code given
    /// in `PI2_PAIR`, so that `scripts/test-copy pair` can type them on the Mac as the person would after reading them
    /// here (section 10).
    static func shown(digits: String, for code: PairingPayload) {
        #if targetEnvironment(simulator)
        guard let text = payload, (try? PairingPayload.parse(text)) == code else { return }
        Logger(subsystem: "dev.pi2.ios", category: "pairing").notice("digits shown: \(digits, privacy: .public)")
        #endif
    }
}
#endif
