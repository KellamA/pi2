
import CryptoKit
import Foundation
import os
import RemoteKit

/// The phone's side of the pairing exchange (docs/iphone.md 3.3), from a payload RemoteKit's reader took to the record
/// kept: both paths tried at once (the relay's join and the home network), the IKpsk2 handshake over the first, the
/// Mac's proof checked against the scanned identity key, `pair` with the attestation bound to the device key, the six
/// digits for the person to type on the Mac, and the Mac's `paired`.
///
/// Nothing is kept unless the Mac paired: a failure at any step deletes the keys made for it.
struct PairingExchange: Sendable {
    let payload: PairingPayload
    let keyStore: any PairingKeySource
    let attester: any AppAttesting
    let store: any PairingStore
    let phone: PhoneDescription
    var routes = Routes()
    var now: @Sendable () -> Date = { Date() }

    /// How the exchange ended other than in a pairing, in the words the phone shows (`PairingFailure.words`).
    enum Failure: Error, Equatable, Sendable {
        /// The code's five minutes are over (3.1).
        case expired
        /// Neither the relay nor the home network reached the Mac.
        case unreachable
        /// The relay refused the join, with its word: a wrong or used code (`token`), the window closed, an attestation
        /// refused, or another of the relay's words.
        case relayRefused(RelayWord)
        /// This build has no App Attest and the Mac was not found on this network: the relay takes no join without one.
        case noAppAttest
        /// What answered did not prove it holds the Mac's identity key from the code: nothing was sent to it.
        case macNotProved
        /// The Mac closed the channel without pairing: the digits typed did not match, another device tried the code,
        /// the window closed, or the Mac refused the claim.
        case macDidNotPair
        /// App Attest did not attest the key.
        case attestation
        /// The phone could not make or keep its keys, or its record.
        case keys
    }

    /// Runs the exchange. `showDigits` is told the six digits once `pair` is sent, for the person to type on the Mac.
    func run(showDigits: @escaping @Sendable (String) async -> Void, reaching: @escaping @Sendable (AppSession.Path) async -> Void = { _ in }) async throws -> PairingRecord {
        guard payload.isOpen(at: now()) else { throw Failure.expired }
        let device: DeviceStatementSigner
        let keys: PairedKeys
        do {
            // The device key first: the join's attestation binds it (3.3 step 2). The other keys come before the
            // handshake, which needs the channel key: the presence key's making asks no Face ID (3.2).
            device = try DeviceStatementSigner(try await keyStore.makeDeviceKey())
            _ = try await keyStore.makePairingKeys()
            guard let made = try await keyStore.pairedKeys() else { throw Failure.keys }
            keys = made
        } catch {
            // What Keys/ said, in its own words (no key material), for working out why on a phone or a simulator.
            Logger(subsystem: "dev.pi2.ios", category: "pairing").notice("the keys were not made: \(String(describing: error), privacy: .public)")
            try? await keyStore.wipe()
            throw Failure.keys
        }
        do {
            let reached = try await reach(device: device)
            await reaching(reached.path)
            let record = try await exchange(over: reached, keys: keys, showDigits: showDigits)
            do {
                try store.save(record)
            } catch {
                throw Failure.keys
            }
            return record
        } catch {
            try? await keyStore.wipe()
            throw (error as? Failure) ?? Self.failure(error)
        }
    }

    private static func failure(_ error: any Error) -> Failure {
        switch error as? LinkError {
        case let .relay(word)?: .relayRefused(word)
        case .noAppAttest?: .noAppAttest
        default: .unreachable
        }
    }

    /// Both paths at once (step 1), the first link kept.
    private func reach(device: DeviceStatementSigner) async throws -> Reached {
        var attempts = HomeReach.attempts(addresses: payload.addresses, homeKey: nil, pairing: payload.pairing, routes: routes)
        if let relay = URL(string: payload.relay) {
            let payload = payload, attester = attester, routes = routes
            let deviceKey = device.publicKey
            attempts.append {
                try await Self.join(relay: relay, payload: payload, deviceKey: deviceKey, attester: attester, routes: routes)
            }
        }
        return try await Race.first(attempts)
    }

    /// The relay's join (step 2), with an App Attest key made for it alone. The client data hash is RemoteKit's, from
    /// the relay's challenge and this phone's own device key, never from a key or hash given from outside.
    private static func join(relay: URL, payload: PairingPayload, deviceKey: P256.Signing.PublicKey, attester: any AppAttesting, routes: Routes) async throws -> Reached {
        let token = PairingSecrets.joinToken(secret: payload.secret, pairing: payload.pairing)
        do {
            let link = try await RelayClient.join(
                relay: relay, pairing: payload.pairing, build: RelayBuild(PhoneDescription.bundleBuild) ?? RelayBuild("1")!, deviceKey: deviceKey, token: token,
                attest: { hash in
                    guard let attestation = try await attester.attestNewKey(clientDataHash: hash).forRelay else { throw LinkError.noAppAttest }
                    return attestation
                },
                connector: routes.relayConnector, options: routes.relayOptions)
            return Reached(link: JoinMessageLink(link), path: .relay)
        } catch let error as LinkError {
            throw error
        } catch let RelayClientError.refused(why) {
            throw LinkError.relay(RelayWord(word: why.word))
        } catch let RelayClientError.http(status) {
            throw LinkError.relay(RelayWord(word: "http-\(status)"))
        } catch {
            throw LinkError.closed
        }
    }

    /// Steps 3 to 8 over the link.
    private func exchange(over reached: Reached, keys: PairedKeys, showDigits: @escaping @Sendable (String) async -> Void) async throws -> PairingRecord {
        let handshake = try ChannelHandshake.pairingInitiator(payload: payload, channelKey: keys.channel)
        let channel: OpenChannel
        do {
            channel = try await OpenChannel.open(handshake, over: reached.link, path: reached.path, within: .seconds(20))
        } catch {
            // A wrong pre-shared key, or a Mac that is not there: the Mac says nothing either way (remotekit.md).
            throw Failure.macDidNotPair
        }
        var handedBack = false
        defer { if !handedBack { channel.drop() } }
        let binding = channel.channel.handshakeHash

        guard let first = try? await channel.nextLine(within: .seconds(20)) else { throw Failure.macDidNotPair }
        guard case let .mac(proof)? = try? ControlLine.parse(first, from: .mac) else { throw Failure.macNotProved }
        do {
            try proof.verify(identityKey: payload.identityKey, pairing: payload.pairing, binding: binding)
        } catch {
            throw Failure.macNotProved
        }

        // The Mac's App Attest key: a second new one, never the relay's, over the challenge, this device key and this
        // channel (step 4).
        let deviceSigner: DeviceStatementSigner
        let description: DeviceDescription
        do {
            deviceSigner = try DeviceStatementSigner(keys.device)
            description = try keys.publicKeys.description(of: phone)
        } catch {
            throw Failure.keys
        }
        let attested: (object: Data?, keyId: String?)
        do {
            attested = try await attester.attestNewKey(
                clientDataHash: PairingSecrets.attestationClientDataHash(challenge: proof.challenge, deviceKey: deviceSigner.publicKey, binding: binding)
            ).forPair
        } catch {
            throw Failure.attestation
        }
        let claim: PairClaim
        do {
            claim = try PairClaim.make(device: description, attestation: attested.object, keyId: attested.keyId, pairing: payload.pairing, binding: binding, deviceKey: deviceSigner)
        } catch {
            throw Failure.keys
        }
        try channel.send(.pair(claim))
        await showDigits(PairingSecrets.digits(secret: payload.secret, binding: binding))

        // The person types the digits on the Mac, within the window's five minutes.
        let window = max(Double(payload.expires) - now().timeIntervalSince1970, 0) + 30
        guard let answer = try? await channel.nextLine(within: .seconds(window)) else { throw Failure.macDidNotPair }
        guard case let .paired(paired)? = try? ControlLine.parse(answer, from: .mac), paired.pairing == payload.pairing else { throw Failure.macDidNotPair }
        handedBack = true
        channel.close()
        return PairingRecord(payload: payload, paired: paired, at: now())
    }
}
