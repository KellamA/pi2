
import CryptoKit
import Foundation
import Network
import RemoteKit

/// Finds the paired Mac on the network the phone is on (docs/iphone.md 5.4): pi² Remote advertises `_pi2._tcp` with a
/// TXT record `v=2` and `t=<tag>`, and the phone takes a service only by the tag (`HomeTag.recognises`, the UTC day
/// before, of and after its own clock's), never by its name, which any device on the network can choose. Finding the
/// tag is not trusting it: the channel's KK handshake, which only the Mac's channel key answers, still decides.
protocol HomeFinder: Sendable {
    /// The endpoints of services that carry this pairing's tag, as they are found, until the task is cancelled.
    func find(macChannelKey: Curve25519.KeyAgreement.PublicKey, pairing: PairingID) -> Inbox<NWEndpoint>
}

/// Bonjour, through Network.framework's browser. Browsing asks the phone's owner once for Local Network (5.4), so the
/// app browses in the foreground only, and first while pairing; the project lists `_pi2._tcp` in `NSBonjourServices`
/// with a usage text (the app's follow-up: see docs/iphone-app.md).
struct BonjourHomeFinder: HomeFinder {
    static let serviceType = "_pi2._tcp"

    func find(macChannelKey: Curve25519.KeyAgreement.PublicKey, pairing: PairingID) -> Inbox<NWEndpoint> {
        let found = Inbox<NWEndpoint>()
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: NWParameters())
        browser.browseResultsChangedHandler = { _, changes in
            for change in changes {
                guard case let .added(result) = change else { continue }
                if Self.recognises(result.metadata, macChannelKey: macChannelKey, pairing: pairing) { found.push(result.endpoint) }
            }
        }
        browser.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: found.finish()
            default: break
            }
        }
        browser.start(queue: DispatchQueue(label: "dev.pi2.ios.bonjour"))
        // The browser stops when its reader lets go: `HomeLinks` cancels its task, then closes the inbox.
        Task {
            while !found.isFinished { try? await Task.sleep(for: .milliseconds(250)) }
            browser.cancel()
        }
        return found
    }

    /// Whether a service's TXT record names this pairing's Mac today: `v=2` and a tag `HomeTag` takes.
    static func recognises(_ metadata: NWBrowser.Result.Metadata, macChannelKey: Curve25519.KeyAgreement.PublicKey, pairing: PairingID, now: Date = Date()) -> Bool {
        guard case let .bonjour(record) = metadata else { return false }
        return recognises(version: record["v"], tag: record["t"], macChannelKey: macChannelKey, pairing: pairing, now: now)
    }

    static func recognises(version: String?, tag: String?, macChannelKey: Curve25519.KeyAgreement.PublicKey, pairing: PairingID, now: Date = Date()) -> Bool {
        guard version == "2", let tag else { return false }
        return HomeTag.recognises(tag, macChannelKey: macChannelKey, pairing: pairing, now: now)
    }
}
