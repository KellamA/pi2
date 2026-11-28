import CryptoKit
import EngineKit
import Foundation
import PiModels
import RemoteKit
import Testing
@testable import pi2

/// A notification button's answer against the relay itself (#691; docs/iphone.md 10, 7): the phone pairs through the
/// local relay (the same way `RelayPairingTests` does), attaches, and a button's answer reaches the Mac over it; then,
/// the Mac still connected but the answer sent while the Mac's session is closed, what the phone put in the Mac's
/// mailbox is taken there and opens and verifies, with the device key's and the session's presence signatures — the
/// check the engine makes of a mailbox item (4.3). Run only when `PI2_RELAY` names the local relay
/// (`TEST_RUNNER_PI2_RELAY=ws://127.0.0.1:<port>/v1` for xcodebuild).
@MainActor
@Suite(.serialized, .enabled(if: TestPlaces.relay != nil, "PI2_RELAY names no local relay"))
struct RelayNotificationsTests {
    static var relay: URL? { TestPlaces.relay }

    private static func routes() -> Routes {
        var routes = Routes()
        routes.homeFinder = nil
        var options = RelayOptions()
        options.backoff = RelayBackoff(first: 200, longest: 2_000)
        options.answerWithin = 20_000
        routes.relayOptions = options
        return routes
    }

    /// Pairs the phone with a test Mac through the local relay, with no address but the relay's.
    private func paired() async throws -> (TestMac, PairingRecord, MemoryKeyStore, MemoryPairingStore) {
        let url = try #require(Self.relay)
        let mac = TestMac(rules: TestMac.Rules(answersNeeds: true))
        try await mac.joinRelay(url)
        let keys = MemoryKeyStore(), store = MemoryPairingStore()
        let payload = try mac.payload(relay: url.absoluteString, addresses: [])
        let typed = mac.typed
        let record = try await PairingExchange(payload: payload, keyStore: keys, attester: StandInAttester(), store: store, phone: .test, routes: Self.routes())
            .run(showDigits: { typed.push($0) }, reaching: { _ in })
        return (mac, record, keys, store)
    }

    @Test func aButtonsAnswerGoesOverTheRelayAndToTheMailbox() async throws {
        let (mac, record, keys, store) = try await paired()
        defer { mac.stop() }
        let device = try #require(mac.state.withLock { $0.paired.first })
        let phoneKeys = try #require(try keys.keys())

        // Attached over the relay, the engine's cards in front of the phone.
        let connection = try RemoteConnection(record: record, keys: phoneKeys, keyStore: keys, store: store, routes: Self.routes())
        connection.backoff = RelayBackoff(first: 100, longest: 500)
        let session = AppSession()
        session.start(connection.transport(), as: .connecting)
        connection.start()
        #expect(await Wait.until(90) { connection.connection == .connected(.relay, relayReachable: true) })
        #expect(await Wait.until(90) { !session.engine.needs.isEmpty && session.engine.needs.first { $0.kind == "approval" } != nil })

        // **Deny** on the recorded approval's notification: the answer over the relay, the engine's, taken.
        let approval = try #require(session.engine.needs.first { $0.kind == "approval" })
        var taken: Set<String> = []
        await PushActions.run(
            PushResponse(
                action: PushCategories.Action.deny.rawValue,
                userInfo: [PushUserInfo.need: approval.id, PushUserInfo.kind: "approval",
                           PushUserInfo.projectId: approval.projectId ?? "", PushUserInfo.conversationId: approval.conversationId],
                reply: nil),
            session: session, isOpen: { true }, outbox: nil, mailbox: nil, takeAway: { taken = $0 },
            faceIDWithin: .seconds(2), cardWithin: .seconds(30))
        #expect(mac.state.withLock { $0.requests.contains("inbox.decide") || $0.requests.contains("needs.answer") },
                "the answer reached the engine over the relay")
        #expect(taken == [approval.id])

        // While the Mac's session is closed, an answer waits sealed in the Mac's mailbox at the relay, and opens and
        // verifies there with both signatures (4.3) — the session's own presence key, as on the channel.
        let presence = try #require(try keys.software?.softwarePresence, "the pairing's presence key")
        let phoneRecord = P256.KeyAgreement.PrivateKey()
        let ends = PushMailbox.Ends(
            pairing: try #require(PairingID(record.pairing)), device: device, macRecordKey: mac.recordKey.publicKey, recordKey: phoneRecord,
            deviceKey: phoneKeys.device, presence: presence)
        guard case .success(let item) = OutboxItem.make("inbox.decide", ["id": "n-1", "decision": "once"], at: Date()) else {
            throw TestError("the Outbox did not take the answer")
        }
        let courier = PushMailbox(ends: { ends }, put: { sealed, id, presenceMark in
            guard let answer = await connection.putInMailbox(sealed, id: id, presence: presenceMark, within: .seconds(20)), answer else {
                throw RemoteKitError("mailbox", "the relay would not take it")
            }
        })
        await #expect(courier.deliver(item) == .inMailbox)
        try await mac.takeMailbox()
        let handed = try #require(mac.mailItems.withLock { $0 }.first(where: { $0.id.text == item.id }))
        #expect(handed.presence == item.widens)
        let opened = try SealedItem.openRequest(
            handed.item, at: ItemAddress(pairing: try #require(PairingID(record.pairing)), reader: .mac, id: handed.id),
            readerKey: mac.recordKey, writer: device, writerRecordKey: phoneRecord.publicKey,
            deviceKey: try #require(PublicKeys.signingKey(fromBase64URL: Base64URL.encode(phoneKeys.device.publicKeyDER))),
            presenceKey: presence.key.publicKey)
        #expect(opened.method == "inbox.decide")
        #expect(opened.params["decision"]?.stringValue == "once")
        #expect(opened.params["id"]?.stringValue == "n-1")
    }
}

/// A test's own failure.
private struct TestError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
