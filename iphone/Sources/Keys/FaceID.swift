import Foundation
import LocalAuthentication

/// Why a session could not open (docs/iphone.md 4.5), each with its own words on the lock screen.
enum SessionFailure: Error, Equatable, Sendable {
    /// Face ID is not set up on this phone.
    case noFaceID
    /// Face ID is locked after too many tries, until the passcode is entered.
    case faceIDLockedOut
    /// The person turned Face ID off for pi² in Settings.
    case faceIDNotAllowed
    /// The phone has neither Face ID nor Touch ID.
    case noBiometrics
    /// The phone has no passcode.
    case noPasscode
    /// Face ID did not recognise the face.
    case notRecognised
    /// Face ID was enrolled again since the presence key was made: the key went with the old enrolment, a new one was
    /// made and waits for the person to accept it on the Mac (3.2).
    case faceIDSetUpAgain
    /// The phone has no presence key: not paired, or its keys were deleted (the passcode turned off).
    case keysGone
    /// Anything else, with LocalAuthentication's code.
    case other(Int)
}

/// One Face ID that passed: its context, which the presence key signs under until the session ends (4.3).
@MainActor
protocol FaceIDPass: AnyObject {
    /// The context Face ID evaluated. Nil only for a test's stand-in.
    var context: LAContext? { get }
    /// LocalAuthentication's hash of the faces enrolled when it passed.
    var stateHash: Data? { get }
    func invalidate()
}

enum FaceIDOutcome {
    case passed(any FaceIDPass)
    /// The person, the system or the app cancelled: back to locked, with nothing to say.
    case cancelled
    case failed(SessionFailure)
}

/// Asking Face ID. `LocalFaceID` is the real one; tests give a stand-in.
@MainActor
protocol FaceIDGate: AnyObject {
    /// Whether Face ID can be asked, with the hash of the faces enrolled, or why not. Shows nothing.
    func availability() -> Result<Data?, SessionFailure>
    /// Asks Face ID once, in a new context: biometrics only, no passcode fallback.
    func check(reason: String) async -> FaceIDOutcome
}

/// LocalAuthentication's Face ID, with the policy for biometrics alone: `.deviceOwnerAuthenticationWithBiometrics`
/// never offers the passcode, and an empty fallback title hides "Enter Password" after a failed try (4.5).
@MainActor
final class LocalFaceID: FaceIDGate {
    func availability() -> Result<Data?, SessionFailure> {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return .failure(Self.failure(code: error?.code, biometry: context.biometryType))
        }
        return .success(context.domainState.biometry.stateHash)
    }

    func check(reason: String) async -> FaceIDOutcome {
        let context = LAContext()
        context.localizedFallbackTitle = ""
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return .failed(Self.failure(code: error?.code, biometry: context.biometryType))
        }
        let refusal: Int? = await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { passed, error in
                continuation.resume(returning: passed ? nil : ((error as NSError?)?.code ?? LAError.Code.authenticationFailed.rawValue))
            }
        }
        if let refusal {
            switch LAError.Code(rawValue: refusal) {
            case .userCancel, .systemCancel, .appCancel, .userFallback, .notInteractive: return .cancelled
            default: return .failed(Self.failure(code: refusal, biometry: context.biometryType))
            }
        }
        // From here on the context shows nothing: a use that would need Face ID's interface again fails instead of
        // asking, so the session knows one check did not hold (4.3) rather than surprising the person with a prompt.
        context.interactionNotAllowed = true
        return .passed(LocalFaceIDPass(context: context))
    }

    static func failure(code: Int?, biometry: LABiometryType) -> SessionFailure {
        switch code.flatMap(LAError.Code.init(rawValue:)) {
        case .biometryNotEnrolled: .noFaceID
        case .biometryLockout: .faceIDLockedOut
        case .biometryNotAvailable: biometry == .none ? .noBiometrics : .faceIDNotAllowed
        case .passcodeNotSet: .noPasscode
        case .authenticationFailed: .notRecognised
        default: .other(code ?? 0)
        }
    }
}

@MainActor
final class LocalFaceIDPass: FaceIDPass {
    private var live: LAContext?
    let stateHash: Data?

    init(context: LAContext) {
        live = context
        stateHash = context.domainState.biometry.stateHash
    }

    var context: LAContext? { live }

    func invalidate() {
        live?.invalidate()
        live = nil
    }
}
