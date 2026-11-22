#if DEBUG
import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// The check docs/iphone.md 4.3 asks for on a real phone before the session is built on it: that a Secure Enclave key
/// with `biometryCurrentSet` (the presence key's access control, 3.2) signs again and again under one `LAContext` that
/// Face ID evaluated once, with no new prompt, until the context is invalidated, and not after.
///
/// It makes a key for itself, asks Face ID once, then loads the key afresh with that context for each of 20 messages,
/// as each new connection of a session will, and signs. The context is set not to show any interface after Face ID,
/// so a signature that would have needed a new prompt fails with "interaction not allowed" instead of asking, and is
/// counted. Then it invalidates the context and tries once more, which must be refused. The key lives only in this
/// function: a Secure Enclave key made by CryptoKit is not in the Keychain, and without the wrapped blob held here it
/// cannot be used again, so nothing is kept. Debug builds only.
enum FaceIDCheck {
    static let signatures = 20

    struct Report: Sendable {
        /// What a person reads back, in one line.
        var line: String
        /// What happened at each step, for when the line is not the expected one.
        var details: [String]
    }

    nonisolated static func run() async -> Report {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let system = "iOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        guard SecureEnclave.isAvailable else {
            return Report(
                line: "Cannot run here: there is no Secure Enclave (the simulator has none). Run it on an iPhone.",
                details: []
            )
        }
        var details: [String] = []

        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, [.privateKeyUsage, .biometryCurrentSet], &accessError
        ) else {
            let why = accessError.map { describe($0.takeRetainedValue()) } ?? "no reason given"
            return Report(line: "Could not make the access control: \(why) (\(system))", details: [])
        }

        let context = LAContext()
        // Face ID alone: no "Enter Passcode" button, as the session will have none (4.5).
        context.localizedFallbackTitle = ""
        var canError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &canError) else {
            let why = canError.map { describe($0) } ?? "no reason given"
            return Report(line: "Face ID cannot be used on this phone: \(why) (\(system))", details: [])
        }

        // Making the key asks for nothing; only using it does.
        let blob: Data
        let publicKey: P256.Signing.PublicKey
        do {
            let key = try SecureEnclave.P256.Signing.PrivateKey(
                compactRepresentable: false, accessControl: access, authenticationContext: context
            )
            blob = key.dataRepresentation
            publicKey = key.publicKey
            details.append("Made a Secure Enclave P-256 key with biometryCurrentSet.")
        } catch {
            return Report(line: "Could not make the key: \(describe(error)) (\(system))", details: details)
        }

        do {
            try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Check that one Face ID can sign many times."
            )
            details.append("Face ID passed once.")
        } catch {
            return Report(line: "Face ID was not passed: \(describe(error)) (\(system))", details: details)
        }

        // From here on, anything that would need Face ID's interface again fails instead of showing it.
        context.interactionNotAllowed = true

        var signed = 0
        var neededPrompt = 0
        var failed = 0
        for index in 1...signatures {
            let message = Data("pi² presence check \(index) \(UUID().uuidString)".utf8)
            do {
                let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob, authenticationContext: context)
                let signature = try key.signature(for: message)
                if publicKey.isValidSignature(signature, for: message) {
                    signed += 1
                } else {
                    failed += 1
                    details.append("Signature \(index): made, but it does not verify.")
                }
            } catch {
                if needsInteraction(error) {
                    neededPrompt += 1
                    details.append("Signature \(index): would have asked Face ID again (\(describe(error))).")
                } else {
                    failed += 1
                    details.append("Signature \(index): failed: \(describe(error)).")
                }
            }
        }
        details.append("\(signed) of \(signatures) signatures made and verified under the one Face ID.")

        context.invalidate()
        let after: String
        do {
            let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob, authenticationContext: context)
            _ = try key.signature(for: Data("pi² presence check after invalidate".utf8))
            after = "SIGNED, which it must not"
            details.append("After invalidate: a signature was made.")
        } catch {
            after = needsInteraction(error) ? "would ask Face ID again" : "refused"
            details.append("After invalidate: \(describe(error)).")
        }
        details.append("The key was never put in the Keychain, and is gone with this check.")

        var line: String
        if signed == signatures {
            line = "\(signatures) signatures, 1 Face ID check"
        } else {
            line = "\(signed) of \(signatures) signatures under 1 Face ID check"
            if neededPrompt > 0 { line += ", \(neededPrompt) needed a new one" }
            if failed > 0 { line += ", \(failed) failed" }
        }
        line += "; after invalidate: \(after) (\(system))"
        return Report(line: line, details: details)
    }

    /// Whether an error says the operation needed Face ID's interface, which the context no longer allowed.
    private static func needsInteraction(_ error: Error) -> Bool {
        if let crypto = error as? CryptoKitError, case .underlyingCoreCryptoError(let code) = crypto {
            return code == errSecInteractionNotAllowed
        }
        var current: NSError? = error as NSError
        while let ns = current {
            if ns.domain == LAErrorDomain, ns.code == LAError.Code.notInteractive.rawValue { return true }
            if ns.domain == NSOSStatusErrorDomain, ns.code == Int(errSecInteractionNotAllowed) { return true }
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// An error as a short text with its domain and code, so that a line sent back says exactly what happened.
    private static func describe(_ error: Error) -> String {
        if let crypto = error as? CryptoKitError, case .underlyingCoreCryptoError(let code) = crypto {
            return "CryptoKit core error \(code)"
        }
        let ns = error as NSError
        var text = "\(ns.domain) \(ns.code)"
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += ", under \(underlying.domain) \(underlying.code)"
        }
        return "\(text): \(ns.localizedDescription)"
    }
}
#endif
