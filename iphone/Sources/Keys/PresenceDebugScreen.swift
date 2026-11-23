#if DEBUG
import CryptoKit
import SwiftUI

/// What a debug build shows instead of the Face ID check when `PI2_LOCK_SCREEN` is in its environment, for pictures
/// of the lock screen and a try of the session in the simulator, with no tap (`scripts/iphone-sim run pi2-… --env
/// PI2_SHOW=face-id-check --env PI2_LOCK_SCREEN=…`):
///
/// - a state's name (`locked`, `locked-away`, `opening`, `not-recognised`, `no-face-id`, `locked-out`, `not-allowed`,
///   `no-biometrics`, `no-passcode`, `set-up-again`, `keys-gone`) draws the lock screen in that state;
/// - `live` runs a real session: the keyring as this build has it (in the simulator, software keys in
///   `SimulatorKeyFile`, made here if there are none), the lock screen asking the simulator's Face ID at once, and,
///   once it opens, twenty presence signatures under it, each checked against the presence key's public half.
enum PresenceDebug {
    static var requested: String? { ProcessInfo.processInfo.environment["PI2_LOCK_SCREEN"] }

    static func state(named name: String) -> (PresenceSession.State, PresenceSession.EndReason?)? {
        switch name {
        case "locked": (.locked, nil)
        case "locked-away": (.locked, .awayTooLong)
        case "opening": (.opening, nil)
        case "not-recognised": (.failed(.notRecognised), nil)
        case "no-face-id": (.failed(.noFaceID), nil)
        case "locked-out": (.failed(.faceIDLockedOut), nil)
        case "not-allowed": (.failed(.faceIDNotAllowed), nil)
        case "no-biometrics": (.failed(.noBiometrics), nil)
        case "no-passcode": (.failed(.noPasscode), nil)
        case "set-up-again": (.failed(.faceIDSetUpAgain), nil)
        case "keys-gone": (.failed(.keysGone), nil)
        default: nil
        }
    }
}

struct PresenceDebugScreen: View {
    let request: String

    var body: some View {
        Group {
            if request == "live" {
                PresenceLiveCheck()
            } else if let (state, lastEnd) = PresenceDebug.state(named: request) {
                PresenceLockContent(state: state, lastEnd: lastEnd) {}
            } else {
                Text("PI2_LOCK_SCREEN=\(request) is not a state this build knows.")
                    .padding()
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// A real session in this build, and twenty presence signatures under its one Face ID.
private struct PresenceLiveCheck: View {
    @MainActor private static let keyring = PhoneKeyring.live()
    private var keyring: PhoneKeyring { Self.keyring }
    @State private var setUp: String?
    @State private var line: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Session open")
                .font(.title2.bold())
            Text(line ?? "Signing…")
                .font(.body.monospaced())
                .multilineTextAlignment(.center)
            Text(keyring.session.fellBack ? "One check did not sign again: each connection asks Face ID." : "Mode: \(keyring.session.mode == .oneCheckPerSession ? "one check for the session" : "a check per connection")")
                .font(.footnote)
                .foregroundStyle(.secondary)
            PresenceLockButton(session: keyring.session)
                .buttonStyle(.bordered)
            if let setUp {
                Text(setUp)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .presenceGate(keyring.session)
        .task {
            do {
                if try !keyring.keys.hasPresenceKey() {
                    try keyring.keys.makeDeviceKey()
                    _ = try keyring.makePairingKeys()
                    setUp = "Made a device key and the pairing keys for this check (\(keyring.keys.secureEnclave ? "Secure Enclave" : "software, as in the simulator"))."
                }
            } catch {
                setUp = "Could not make the keys: \(error.localizedDescription)"
            }
        }
        .onChange(of: keyring.session.state) { _, state in
            guard state == .open else { return }
            Task { line = await sign() }
        }
    }

    private func sign() async -> String {
        guard let der = try? keyring.session.presencePublicKeyDER(), let publicKey = try? P256PublicKey(der) else {
            return "No Face ID key."
        }
        var good = 0
        for index in 1...20 {
            let message = Data("pi² presence check \(index)".utf8)
            guard let signature = try? await keyring.session.signPresence(message) else { continue }
            if publicKey.verifies(signature, message) { good += 1 }
        }
        return "\(good) of 20 presence signatures verified under 1 Face ID check (\(keyring.keys.secureEnclave ? "Secure Enclave" : "software key"))"
    }
}

private struct P256PublicKey {
    let key: P256.Signing.PublicKey
    init(_ der: Data) throws { key = try P256.Signing.PublicKey(derRepresentation: der) }
    func verifies(_ signature: Data, _ message: Data) -> Bool {
        guard let ecdsa = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else { return false }
        return key.isValidSignature(ecdsa, for: message)
    }
}
#endif
