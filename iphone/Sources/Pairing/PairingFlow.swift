
import Foundation
import Observation
import RemoteKit

/// Pairing as the person goes through it (docs/design/iphone.md, "Pairing"; docs/iphone.md 3.1, 3.3): the code
/// scanned, the question before replacing a pairing, reaching the Mac, the six digits to type on it, and then paired,
/// or why not, in plain words. The screens (`PairingView`) draw `step`; `PairingExchange` does the work.
@MainActor
@Observable
final class PairingFlow {
    enum Step: Equatable {
        case scanning
        /// A phone already paired scanned another Mac's code (3.3, "Pairing again").
        case replace(current: String, new: String)
        case reaching(mac: String)
        case digits(String, mac: String, path: AppSession.Path)
        case paired(mac: String)
        case failed(PairingFailure)
    }

    /// What pairing needs from outside: the keyring (`PhoneKeyring` is a `PairingKeySource`) and its App Attest
    /// (`keyring.attester`), where the Mac's record is kept (`KeychainPairingStore(keys: keyring.keys)`), what the phone says of
    /// itself, and the paths. `unpair` ends the current pairing before a new one: the app's, since it holds the
    /// connection (`RemoteConnection.unpairHere`).
    struct Needs: Sendable {
        var keyStore: any PairingKeySource
        var attester: any AppAttesting
        var store: any PairingStore
        var phone: PhoneDescription
        var routes = Routes()
        var unpair: @MainActor @Sendable () async -> Void = {}
        var now: @Sendable () -> Date = { Date() }
    }

    private(set) var step: Step = .scanning
    /// The record kept, once paired.
    private(set) var record: PairingRecord?

    private let needs: Needs
    private var pending: PairingPayload?
    private var task: Task<Void, Never>?

    init(needs: Needs) {
        self.needs = needs
    }

    /// A code the scanner read: RemoteKit's reader, and nothing else, decides what it is. A release build takes a code
    /// from its camera alone; a debug build also from its launch value (`PairingDebugLaunch`).
    func scanned(_ text: String) {
        guard step == .scanning else { return }
        guard let payload = try? PairingPayload.parse(text) else {
            step = .failed(.notACode)
            return
        }
        guard payload.isOpen(at: needs.now()) else {
            step = .failed(.expired)
            return
        }
        if let current = try? needs.store.load() {
            pending = payload
            step = .replace(current: current.macName, new: payload.macName)
            return
        }
        pair(payload)
    }

    /// Yes to "Replace your pairing with ‹Mac›?": unpairs first, then pairs (3.3).
    func replace() {
        guard case .replace = step, let payload = pending else { return }
        pending = nil
        step = .reaching(mac: payload.macName)
        let needs = needs
        task = Task {
            await needs.unpair()
            try? await needs.keyStore.wipe()
            try? needs.store.delete()
            self.pair(payload)
        }
    }

    /// Back to the scanner: after "Keep", or to try again after a failure.
    func scanAgain() {
        task?.cancel()
        task = nil
        pending = nil
        step = .scanning
    }

    private func pair(_ payload: PairingPayload) {
        step = .reaching(mac: payload.macName)
        let exchange = PairingExchange(payload: payload, keyStore: needs.keyStore, attester: needs.attester, store: needs.store, phone: needs.phone, routes: needs.routes, now: needs.now)
        let name = payload.macName
        task = Task {
            let path = PathBox()
            do {
                let record = try await exchange.run(
                    showDigits: { digits in
                        let reached = await path.path ?? .relay
                        await MainActor.run { self.showDigits(digits, mac: name, path: reached, payload: payload) }
                    },
                    reaching: { reached in await path.set(reached) })
                self.record = record
                self.step = .paired(mac: record.macName)
            } catch is CancellationError {
                return
            } catch {
                self.step = .failed(PairingFailure(error as? PairingExchange.Failure ?? .unreachable))
            }
        }
    }

    private func showDigits(_ digits: String, mac: String, path: AppSession.Path, payload: PairingPayload) {
        guard case .reaching = step else { return }
        step = .digits(digits, mac: mac, path: path)
        #if DEBUG
        PairingDebugLaunch.shown(digits: digits, for: payload)
        #endif
    }
}

private actor PathBox {
    var path: AppSession.Path?
    func set(_ path: AppSession.Path) { self.path = path }
}

/// Why pairing did not happen, in the words the phone shows.
enum PairingFailure: Equatable, Sendable {
    case notACode
    case expired
    case unreachable
    case relayRefused(String)
    case noAppAttest
    case macNotProved
    case macDidNotPair
    case macCouldNotSave
    case cancelledOnMac
    case attestation
    case keys

    init(_ failure: PairingExchange.Failure) {
        switch failure {
        case .expired: self = .expired
        case .unreachable: self = .unreachable
        case let .relayRefused(word): self = .relayRefused(word.word)
        case .noAppAttest: self = .noAppAttest
        case .macNotProved: self = .macNotProved
        case .macDidNotPair: self = .macDidNotPair
        case .macCouldNotSave: self = .macCouldNotSave
        case .cancelledOnMac: self = .cancelledOnMac
        case .attestation: self = .attestation
        case .keys: self = .keys
        }
    }

    var title: String {
        switch self {
        case .notACode: "Not a pairing code"
        case .expired: "This code has expired"
        case .unreachable: "Couldn't reach your Mac"
        case .relayRefused: "pi²'s relay didn't take the code"
        case .noAppAttest: "Pair on your Mac's network"
        case .macNotProved: "That wasn't your Mac"
        case .macDidNotPair: "Your Mac didn't pair"
        case .macCouldNotSave: "Your Mac couldn't save the pairing"
        case .cancelledOnMac: "Pairing was cancelled on your Mac"
        case .attestation: "App Attest didn't answer"
        case .keys: "Couldn't make this iPhone's keys"
        }
    }

    var words: String {
        switch self {
        case .notACode:
            "This isn't a pairing code from pi². On your Mac, open pi² › Settings › Devices › Pair an iPhone, and scan the code it shows."
        case .expired:
            "A code is good for five minutes. On your Mac, start pairing again for a new one."
        case .unreachable:
            "pi² couldn't reach your Mac, through pi²'s relay or on this network. Check that your Mac is awake and still shows the code, then scan it again."
        case let .relayRefused(word):
            switch word {
            case "token", "window-closed", "window-ended", "unknown-pairing":
                "The code was used already, has closed, or isn't this Mac's. On your Mac, start pairing again for a new code."
            case "attestation", "category", "bundle-version", "attest-key-taken":
                "pi²'s relay couldn't confirm this is a genuine pi² for iPhone. Install it from TestFlight, then scan again."
            case "update-required":
                "This version of pi² for iPhone is too old for pi²'s relay. Update it from TestFlight, then scan again."
            case "busy", "limits", "too-many", "unavailable", "timeout":
                "pi²'s relay is busy just now. Wait a minute, then scan the code again."
            default:
                "pi²'s relay refused to pair (it says “\(word)”). On your Mac, start pairing again."
            }
        case .noAppAttest:
            "This build can't prove itself to pi²'s relay: it has no App Attest (the simulator has none). Pair with your iPhone on the same network as your Mac."
        case .macNotProved:
            "What answered couldn't prove it is the Mac that showed this code. Nothing was paired, and nothing was sent to it. Start again on your Mac."
        case .macDidNotPair:
            "The digits typed may not have matched, the code may have closed, or another device tried to use it. Start again on your Mac, and don't show the code on a shared or recorded screen."
        case .macCouldNotSave:
            "The Mac could not save the pairing. Start again."
        case .cancelledOnMac:
            "The pairing was cancelled on the Mac. Start again there to pair this iPhone."
        case .attestation:
            "App Attest couldn't vouch for this iPhone just now. Wait a minute, then scan the code again."
        case .keys:
            "pi² couldn't make this iPhone's keys. Check that a passcode and Face ID are set up in Settings, then scan again."
        }
    }
}
