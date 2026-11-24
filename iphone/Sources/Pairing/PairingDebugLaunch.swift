
#if DEBUG
import Foundation

/// A debug build's way to hand the pairing screens a code, since the simulator has no camera (docs/iphone.md 10): the
/// payload's text in `PI2_PAIR` (`scripts/iphone-sim run … --env PI2_PAIR='pi2://pair?…'`), taken as if scanned, by
/// RemoteKit's reader like any code. Not compiled into a release build, which takes a code from its camera alone and
/// registers no `pi2:` scheme (3.1).
enum PairingDebugLaunch {
    static var payload: String? {
        ProcessInfo.processInfo.environment["PI2_PAIR"].flatMap { $0.isEmpty ? nil : $0 }
    }
}
#endif
