
import CryptoKit
import Foundation
import RemoteKit

/// The phone's side of every connection after pairing (docs/iphone.md 3.4, 4.3, 5.8; remotekit.md): the KK handshake
/// with the Mac's channel key kept from pairing, the Mac's proof checked against the identity key kept from pairing,
/// then `attach` signed by the device key and by the presence key, afresh or resuming a session, and the Mac's answer.
enum Attach {
    /// What the Mac answered.
    enum Outcome: Sendable {
        case attached(Attached, OpenChannel)
        /// The Mac did not attach the phone and said why (remotekit.md, "The refused line"); nil for a reason this build
        /// does not know, which is a plain refusal.
        case refused(Refusal.Reason?)
        /// The Mac's identity key revoked this device (3.6), checked here: the only word the phone unpairs on.
        case revoked
        /// The channel closed with no answer: a plain refusal, or a dropped network, which is tried again after a wait.
        case closed
    }

    /// Why an attach failed before the Mac answered.
    enum Failure: Error, Equatable, Sendable {
        /// The Mac's first line was not a proof signed by the identity key kept from pairing, for this pairing and this
        /// channel: whatever answered is not the paired Mac, and nothing is sent to it.
        case macNotProved
        /// The presence key did not sign: no session is open (4.3, 4.5).
        case presence(PresenceError)
        /// The device key did not sign.
        case deviceKey
        /// The Mac sent what is not one of the lines it may send here.
        case unreadable
    }

    /// A session to resume (5.8): its id and the count of the engine's lines the phone has had in it.
    struct Resume: Equatable, Sendable {
        let session: SessionID
        let received: UInt64
    }

    /// How long the Mac has for its proof and its answer: the ten seconds of 3.4, from the handshake.
    static let answerWithin: Duration = .seconds(10)

    /// Makes the channel over `link` and attaches. `now` is this phone's clock, which `at` is signed with: the Mac
    /// takes it within two minutes of its own (3.4), and says `clock` otherwise.
    static func run(
        over link: any MessageLink, path: AppSession.Path, mac: PairedMac, keys: PairedKeys, resume: Resume?, build: String,
        now: @Sendable () -> Date = { Date() }
    ) async throws -> Outcome {
        let handshake = try ChannelHandshake.connection(
            initiator: true, pairing: mac.pairing, device: mac.device, channelKey: keys.channel, remoteChannelKey: mac.channelKey)
        let channel = try await OpenChannel.open(handshake, over: link, path: path, within: answerWithin)
        do {
            let outcome = try await attach(on: channel, mac: mac, keys: keys, resume: resume, build: build, now: now)
            if case .attached = outcome {} else { channel.drop() }
            return outcome
        } catch {
            channel.drop()
            throw error
        }
    }

    private static func attach(
        on channel: OpenChannel, mac: PairedMac, keys: PairedKeys, resume: Resume?, build: String, now: @Sendable () -> Date
    ) async throws -> Outcome {
        guard let first = try await channel.nextLine(within: answerWithin) else { return .closed }
        guard case let .mac(proof)? = try? ControlLine.parse(first, from: .mac) else { throw Failure.macNotProved }
        do {
            try proof.verify(identityKey: mac.identityKey, pairing: mac.pairing, binding: channel.channel.handshakeHash)
        } catch {
            throw Failure.macNotProved
        }

        let claim: AttachClaim
        do {
            claim = try await PresenceSignatures.attach(
                pairing: mac.pairing, device: mac.device, session: resume?.session, received: resume?.received,
                binding: channel.channel.handshakeHash, challenge: proof.challenge, build: build, at: now(),
                deviceKey: keys.device, presence: keys.presence)
        } catch {
            if let presence = PresenceError(error) { throw Failure.presence(presence) }
            throw Failure.deviceKey
        }
        try channel.send(.attach(claim))

        guard let answer = try await channel.nextLine(within: answerWithin) else { return .closed }
        switch try? ControlLine.parse(answer, from: .mac) {
        case let .attached(attached)?:
            channel.channel.maxLineLength = Lines.defaultMaxLength
            return .attached(attached, channel)
        case let .refused(refusal)?:
            return .refused(refusal.reason)
        case let .revoked(revocation)?:
            return try verified(revocation, mac: mac) ? .revoked : .closed
        default:
            throw Failure.unreadable
        }
    }

    /// Whether a `revoked` line is the Mac's word: its identity key's signature, for this pairing and this device. One
    /// that is not is not believed, and the channel is closed as any other that misbehaves.
    static func verified(_ revocation: Revocation, mac: PairedMac) throws -> Bool {
        do {
            try revocation.verify(identityKey: mac.identityKey, pairing: mac.pairing, device: mac.device)
            return true
        } catch {
            throw Failure.unreadable
        }
    }
}
