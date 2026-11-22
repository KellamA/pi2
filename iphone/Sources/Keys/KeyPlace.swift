import CryptoKit

/// Whether this build can make its keys in the Secure Enclave (docs/iphone.md 3.2), or makes them in software, as a
/// debug build in the simulator does (section 10).
///
/// `SecureEnclave.isAvailable` alone does not tell: in the iOS 27.2 simulator on an Apple silicon Mac it answers true,
/// though the simulator has no Secure Enclave of the phone's and proves nothing about one. So the simulator counts as
/// having none, whatever CryptoKit says there.
enum KeyPlace {
    static var secureEnclave: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        SecureEnclave.isAvailable
        #endif
    }
}
