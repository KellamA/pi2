import CryptoKit
import Foundation
import RemoteKit
import Testing
import UserNotifications
@testable import pi2

// The notification service extension's logic, in `iphone/Sources/Push/` (docs/iphone.md section 7, #690, #689): opening a
// sealed push and verifying it, always replacing the text, the category and its buttons, the thread, the Lock Screen's
// placeholders, the extension's own file and taking a notification away. `xcrun simctl push` does not run the service
// extension in an unsigned build (docs/iphone-app.md "The extensions"), so it is tested here.
//
// The sealed pushes below are made by RemoteKit's `PushSealing.seal`, the very call pi² Remote seals the engine's pushes
// with (app/Sources/pi2-remote/Push, #689), under test keys nobody holds, from bodies in the engine's own shape
// (docs/iphone.md 7.1, engine/src/pushes.ts). They are opened by the extension's own code (`PushDelivery` and
// `RemoteKitPushOpener`), and by `CheckOpener` too, an opening worked out apart with CryptoKit from docs/remotekit.md's
// description of the bytes, so that a change to both sides of RemoteKit at once is still caught.

// MARK: Pushes, sealed as pi² Remote seals them

enum Recorded {
    // Test keys: the phone's record key is 32 bytes of 0x11, the Mac's record key 0x22, its identity key 0x33.
    static let phoneRecordKey = Data(repeating: 0x11, count: 32)
    static let macRecord = try! P256.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x22, count: 32))
    static let macIdentity = try! P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x33, count: 32))
    static let macRecordKey = macRecord.publicKey
    static let macIdentityKey = macIdentity.publicKey
    static let pairing = "AQEBAQEBAQEBAQEBAQEBAQ"
    static let device = "dev_AgICAgICAgICAgICAgICAg"
    /// When they were signed: 2026-11-23, 00:00 UTC.
    static let at = Date(timeIntervalSince1970: 1_795_392_000)

    static let keys = PushKeys(
        pairing: pairing, device: device, recordKey: phoneRecordKey,
        macRecordKey: macRecordKey.derRepresentation, macIdentityKey: macIdentityKey.derRepresentation)

    /// Seals an engine's body as pi² Remote does, under the item id of 16 bytes of `idByte`.
    static func seal(_ body: String, kind: PushSealing.Kind = .alert, idByte: UInt8 = 0x0a, at date: Date = at,
                     identity: P256.Signing.PrivateKey = macIdentity, device: String = device) -> String {
        let sealed = try! PushSealing.seal(
            try! JSON.parse(body), kind: kind, pairing: PairingID(pairing)!, device: DeviceID(device)!,
            deviceRecordKey: try! P256.KeyAgreement.PrivateKey(rawRepresentation: phoneRecordKey).publicKey, recordKey: macRecord,
            identity: identity, id: ItemID(PushBase64URL.encode(Data(repeating: idByte, count: 16)))!, at: date)
        return PushBase64URL.encode(sealed)
    }

    /// An alert's body as the engine writes it (7.1's `AlertBody`).
    static func alert(
        _ category: String, title: String, subtitle: String? = "Demo project", body: String, type: String = "need",
        need: String? = "need-1", projectId: String? = "project-demo", conversationId: Int? = 9, whole: Bool = true
    ) -> String {
        var members = [#""v":1"#, #""type":"\#(type)""#, #""category":"\#(category)""#, #""title":"\#(title)""#]
        if let subtitle { members.append(#""subtitle":"\#(subtitle)""#) }
        members.append(#""body":"\#(body)""#)
        if let projectId { members.append(#""projectId":"\#(projectId)""#) }
        if let need { members.append(#""need":"\#(need)""#) }
        if let conversationId { members.append(#""conversationId":\#(conversationId)"#) }
        members.append(#""whole":\#(whole)"#)
        members.append(#""at":1795392000000"#)
        return "{" + members.joined(separator: ",") + "}"
    }

    static let cutCall = String(repeating: "x", count: 166) + "…"

    /// An approval shown whole: "Forge needs approval", "Demo project", "bash: npm test". 1,464 bytes, the least an alert has.
    static let approval = seal(alert("pi2.approval", title: "Forge needs approval", body: "bash: npm test", need: "need-approval-1"), idByte: 0x0a)
    /// An approval whose call was cut at 180 characters (`whole: false`).
    static let approvalCut = seal(alert("pi2.approval", title: "Forge needs approval", body: "bash: rm -rf " + cutCall, need: "need-approval-2", whole: false), idByte: 0x0b)
    /// A question: "Scribe has a question", in Demo project 2.
    static let question = seal(alert(
        "pi2.question", title: "Scribe has a question", subtitle: "Demo project 2", body: "Which branch should the release notes go on?",
        need: "need-question-1", projectId: "project-demo-2", conversationId: 139), idByte: 0x0c)
    /// The background push that takes the approval's notification away.
    static let gone = seal(#"{"v":1,"type":"gone","needs":["need-approval-1"],"at":1795392000000}"#, kind: .background, idByte: 0x0d)

    /// The payload Apple hands the phone, as the relay posts it.
    static func payload(_ sealed: String) -> [AnyHashable: Any] {
        ["aps": ["alert": ["title": "pi²", "body": "Something needs you"], "mutable-content": 1], "sealed": sealed]
    }
}

// MARK: Stand-ins

/// Opens a sealed push as docs/remotekit.md says the bytes are, worked out apart from RemoteKit with CryptoKit: the item,
/// then its 16-byte id; HPKE's authenticated mode with `info` = "pi2-item-v2", 0, the pairing, 0, the reader, 0, the
/// item's id; then `{"v":2,"signed":…,"signature":…}`, the identity key's signature over the exact `signed` text,
/// `signed`'s pairing, device and nonce, and its body `{"body":…,"pad":"000…"}`. Only the checks the bytes need;
/// RemoteKit's own strict reading is RemoteKit's checks'.
struct CheckOpener: PushOpening {
    func open(_ push: SealedPush, keys: PushKeys) throws -> OpenedPush {
        var info = Data("pi2-item-v2".utf8)
        for part in [keys.pairing, keys.device, push.idText] {
            info.append(0)
            info.append(Data(part.utf8))
        }
        let plaintext: Data
        do {
            let reader = try P256.KeyAgreement.PrivateKey(rawRepresentation: keys.recordKey)
            let writer = try P256.KeyAgreement.PublicKey(derRepresentation: keys.macRecordKey)
            var recipient = try HPKE.Recipient(
                privateKey: reader, ciphersuite: .P256_SHA256_AES_GCM_256, info: info,
                encapsulatedKey: push.item.prefix(65), authenticatedBy: writer)
            plaintext = try recipient.open(push.item.dropFirst(65))
        } catch {
            throw PushRefusal.doesNotOpen
        }
        guard let outer = try JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
              let signed = outer["signed"] as? String, let signatureText = outer["signature"] as? String,
              let signature = PushBase64URL.decode(signatureText),
              let identity = try? P256.Signing.PublicKey(derRepresentation: keys.macIdentityKey),
              let ecdsa = try? P256.Signing.ECDSASignature(rawRepresentation: signature),
              identity.isValidSignature(ecdsa, for: Data(signed.utf8)),
              let statement = try JSONSerialization.jsonObject(with: Data(signed.utf8)) as? [String: Any],
              statement["pairing"] as? String == keys.pairing, statement["device"] as? String == keys.device,
              statement["nonce"] as? String == push.idText,
              let kind = statement["kind"] as? String, let at = statement["at"] as? Int64,
              let wrapped = statement["body"] as? [String: Any], wrapped.count == 2,
              let pad = wrapped["pad"] as? String, pad.allSatisfy({ $0 == "0" }), let body = wrapped["body"]
        else { throw PushRefusal.doesNotOpen }
        return OpenedPush(kind: kind, at: at, id: push.idText, body: try JSONSerialization.data(withJSONObject: body))
    }
}

/// An opener that gives what it is told, for what a push says once opened.
struct GivenOpener: PushOpening {
    let kind: String
    let body: [String: Any & Sendable]
    var at: Date = Recorded.at

    func open(_ push: SealedPush, keys: PushKeys) throws -> OpenedPush {
        OpenedPush(
            kind: kind, at: Int64(at.timeIntervalSince1970 * 1000), id: push.idText,
            body: try JSONSerialization.data(withJSONObject: body))
    }
}

// MARK: Tests

struct PushTests {
    private let now = Recorded.at.addingTimeInterval(30)

    private func deliver(_ sealed: String, opener: (any PushOpening)? = CheckOpener(), keys: PushKeys? = Recorded.keys)
        -> (content: UNNotificationContent, outcome: PushDelivery.Outcome)
    {
        PushDelivery.deliver(Recorded.payload(sealed), opener: opener, keys: { keys }, now: now)
    }

    private func buttons(_ category: String) throws -> [String] {
        let found = try #require(PushCategories.all.first { $0.identifier == category }, "a category \(category)")
        return found.actions.map(\.title)
    }

    // MARK: The wire

    @Test func everyRecordedPushIsOfASizeAPushHas() throws {
        for sealed in [Recorded.approval, Recorded.approvalCut, Recorded.question, Recorded.gone] {
            let push = try SealedPush.read(sealed)
            #expect(SealedPush.sizes.contains(push.id.count + push.item.count))
            #expect(push.id.count == 16)
            // A sealed item first, as the relay takes it (relay/src/protocol.ts: `sealed[0] === 0x04`), its id after it.
            #expect(push.item.first == 0x04)
            #expect(push.bytes == PushBase64URL.decode(sealed))
            // The relay's payload stays within Apple's sizes for its class (relay/README.md, "Pushes").
            #expect(sealed.utf8.count <= 4_000)
        }
        #expect(try SealedPush.read(Recorded.approval).idText == PushBase64URL.encode(Data(repeating: 0x0a, count: 16)))
    }

    @Test func aSealOfAnyOtherFormIsRefusedBeforeAnythingIsOpened() {
        let approval = Recorded.approval
        #expect(throws: PushRefusal.noSeal) { try SealedPush.read(["aps": [:]]) }
        #expect(throws: PushRefusal.noSeal) { try SealedPush.read(["sealed": 7]) }
        #expect(throws: PushRefusal.notBase64URL) { try SealedPush.read(approval + "=") }
        #expect(throws: PushRefusal.notBase64URL) { try SealedPush.read(approval.replacingOccurrences(of: "-", with: "+")) }
        #expect(throws: PushRefusal.notBase64URL) { try SealedPush.read(" " + approval) }
        #expect(throws: PushRefusal.wrongSize) { try SealedPush.read(String(approval.dropLast(4))) }
        #expect(throws: PushRefusal.wrongSize) { try SealedPush.read(PushBase64URL.encode(Data(count: 697))) }
    }

    // MARK: Opening, and the text always replaced

    @Test func aRecordedApprovalShowsItsTextCategoryThreadAndButtons() throws {
        let (content, outcome) = deliver(Recorded.approval)
        guard case let .shown(notice) = outcome else { Issue.record("not shown: \(outcome)"); return }
        #expect(content.title == "Forge needs approval")
        #expect(content.subtitle == "Demo project")
        #expect(content.body == "bash: npm test")
        #expect(content.categoryIdentifier == "pi2.approval")
        #expect(content.threadIdentifier == "project-demo")
        #expect(content.userInfo[PushUserInfo.need] as? String == "need-approval-1")
        #expect(content.userInfo[PushUserInfo.kind] as? String == "approval")
        #expect(content.userInfo[PushUserInfo.projectId] as? String == "project-demo")
        #expect((content.userInfo[PushUserInfo.conversationId] as? NSNumber)?.intValue == 9)
        // Nothing of the push's own payload is kept: not its alert, not the sealed bytes.
        #expect(content.userInfo["sealed"] == nil && content.userInfo["aps"] == nil)
        #expect(notice.whole)
        #expect(try buttons(content.categoryIdentifier) == ["Allow once", "Deny", "Open"])
    }

    @Test func aCutCallHasNoAllowOnce() throws {
        let (content, outcome) = deliver(Recorded.approvalCut)
        guard case let .shown(notice) = outcome else { Issue.record("not shown: \(outcome)"); return }
        #expect(!notice.whole)
        #expect(content.body.count == 180 && content.body.hasSuffix("…"))
        #expect(content.categoryIdentifier == "pi2.approval.cut")
        #expect(try buttons(content.categoryIdentifier) == ["Open", "Deny"])
    }

    @Test func aRecordedQuestionHasReplyInItsOwnThread() throws {
        let (content, _) = deliver(Recorded.question)
        #expect(content.title == "Scribe has a question")
        #expect(content.subtitle == "Demo project 2")
        #expect(content.body == "Which branch should the release notes go on?")
        #expect(content.categoryIdentifier == "pi2.question")
        #expect(content.threadIdentifier == "project-demo-2")
        let category = try #require(PushCategories.all.first { $0.identifier == "pi2.question" })
        #expect(category.actions.first is UNTextInputNotificationAction)
        #expect(try buttons("pi2.question") == ["Reply", "Open"])
    }

    @Test func whatDoesNotOpenOrVerifyShowsThePlaceholderWhateverThePushSaid() throws {
        func placeholder(_ result: (content: UNNotificationContent, outcome: PushDelivery.Outcome), _ why: PushRefusal) {
            #expect(result.content.title == "pi²")
            #expect(result.content.body == "Something needs you")
            #expect(result.content.categoryIdentifier.isEmpty)
            #expect(result.content.userInfo.isEmpty)
            #expect(result.outcome == .placeholder(why))
        }
        // A push with words of its own and no seal, as a leaked push key could send.
        placeholder(PushDelivery.deliver(
            ["aps": ["alert": ["title": "Forge needs approval", "body": "Tap Allow once"], "category": "pi2.approval"]],
            opener: CheckOpener(), keys: { Recorded.keys }, now: now), .noSeal)

        // One byte changed anywhere in the item: the tag fails.
        var bytes = try #require(PushBase64URL.decode(Recorded.approval))
        bytes[300] ^= 0x01
        placeholder(deliver(PushBase64URL.encode(bytes)), .doesNotOpen)

        // Moved: the approval's item under the question's id, so HPKE's `info` is not the one it was sealed for.
        let approval = try #require(PushBase64URL.decode(Recorded.approval))
        let question = try #require(PushBase64URL.decode(Recorded.question))
        placeholder(deliver(PushBase64URL.encode(approval.dropLast(16) + question.suffix(16))), .doesNotOpen)

        // Sealed for another device, another pairing, or by another Mac.
        let keys = Recorded.keys
        let other = PushBase64URL.encode(Data(repeating: 0x03, count: 16))
        placeholder(deliver(Recorded.approval, keys: PushKeys(
            pairing: keys.pairing, device: "dev_" + other, recordKey: keys.recordKey,
            macRecordKey: keys.macRecordKey, macIdentityKey: keys.macIdentityKey)), .doesNotOpen)
        placeholder(deliver(Recorded.approval, keys: PushKeys(
            pairing: other, device: keys.device, recordKey: keys.recordKey,
            macRecordKey: keys.macRecordKey, macIdentityKey: keys.macIdentityKey)), .doesNotOpen)
        let stranger = P256.Signing.PrivateKey().publicKey.derRepresentation
        placeholder(deliver(Recorded.approval, keys: PushKeys(
            pairing: keys.pairing, device: keys.device, recordKey: keys.recordKey,
            macRecordKey: keys.macRecordKey, macIdentityKey: stranger)), .doesNotOpen)

        // No keys (not paired, or the Keychain cannot be read), and a build with nothing to open a seal with.
        placeholder(deliver(Recorded.approval, keys: nil), .noKeys)
        placeholder(deliver(Recorded.approval, opener: nil), .noOpener)

        // A day and more after the Mac signed it.
        placeholder(PushDelivery.deliver(
            Recorded.payload(Recorded.approval), opener: CheckOpener(), keys: { Recorded.keys },
            now: Recorded.at.addingTimeInterval(PushItem.oldest + 60)), .tooOld)

        // Dated more than an hour ahead of the phone's clock (a Mac whose clock runs fast); an hour less a minute is shown.
        placeholder(PushDelivery.deliver(
            Recorded.payload(Recorded.approval), opener: CheckOpener(), keys: { Recorded.keys },
            now: Recorded.at.addingTimeInterval(-PushItem.newest - 60)), .tooNew)
        let ahead = PushDelivery.deliver(
            Recorded.payload(Recorded.approval), opener: CheckOpener(), keys: { Recorded.keys },
            now: Recorded.at.addingTimeInterval(-PushItem.newest + 60))
        if case .shown = ahead.outcome {} else { Issue.record("a push an hour less a minute ahead is shown: \(ahead.outcome)") }

        // A background push's content in an alert is not one to show.
        placeholder(deliver(Recorded.gone), .notANotice)
    }

    @Test func theKeychainIsNotReadForAPushWithNoSeal() {
        var read = false
        _ = PushDelivery.deliver(["aps": [:]], opener: CheckOpener(), keys: { read = true; return Recorded.keys })
        #expect(!read)
    }

    #if canImport(RemoteKit)
    @Test func remoteKitOpensTheRecordedPushesAsTheCheckDoes() throws {
        for sealed in [Recorded.approval, Recorded.approvalCut, Recorded.question, Recorded.gone] {
            let push = try SealedPush.read(sealed)
            #expect(try RemoteKitPushOpener().open(push, keys: Recorded.keys).kind == CheckOpener().open(push, keys: Recorded.keys).kind)
        }
        #expect(deliver(Recorded.approval, opener: RemoteKitPushOpener()).content.categoryIdentifier == "pi2.approval")
    }
    #endif

    @Test func withoutRemoteKitTheExtensionShowsOnlyThePlaceholder() {
        #if canImport(RemoteKit)
        #expect(PushOpeners.standard != nil)
        #else
        // Nothing unverified is ever shown: until RemoteKit is linked, every push is the placeholder.
        #expect(PushOpeners.standard == nil)
        #expect(deliver(Recorded.approval, opener: PushOpeners.standard).outcome == .placeholder(.noOpener))
        #endif
    }

    // MARK: The round trip: sealed by pi² Remote's code, opened by the extension's (#689)

    /// Every kind of alert the engine pushes (docs/iphone.md 7.1), sealed as pi² Remote seals it and delivered as the
    /// extension delivers it, through RemoteKit's opener.
    @Test func everyKindOfAlertSealedAsPiRemoteSealsItOpensInTheExtension() throws {
        let alerts: [(String, String, String, String, String)] = [
            ("pi2.approval", "need", "Forge needs approval", "bash: npm test", "pi2.approval"),
            ("pi2.question", "need", "Scribe has a question", "Which branch?", "pi2.question"),
            ("pi2.decision", "need", "The orchestrator asks for a decision", "Ship it now or wait for review", "pi2.decision"),
            ("pi2.reach", "need", "The orchestrator asks for more reach", "Read ~/Documents", "pi2.reach"),
            ("pi2.rule", "need", "Forge proposes a rule", "everyone: run the tests first", "pi2.rule"),
            ("pi2.limit", "limit", "Forge is held back by a limit", "Claude: usage limit reached", "pi2.limit"),
            ("pi2.notice", "answer", "The orchestrator answered", "In Demo project", "pi2.notice"),
        ]
        for (index, (category, type, title, body, shown)) in alerts.enumerated() {
            let sealed = Recorded.seal(Recorded.alert(category, title: title, body: body, type: type), idByte: UInt8(0x40 + index))
            let (content, outcome) = deliver(sealed, opener: RemoteKitPushOpener())
            guard case let .shown(notice) = outcome else { Issue.record("\(category) not shown: \(outcome)"); continue }
            #expect(content.title == title && content.subtitle == "Demo project" && content.body == body, "\(category)")
            #expect(content.categoryIdentifier == shown && notice.kind?.category == category, "\(category)")
            #expect(content.threadIdentifier == "project-demo" && content.userInfo[PushUserInfo.need] as? String == "need-1")
            // And the independent opening reads the same.
            #expect(deliver(sealed).content.body == body)
        }
        // The background push, as the app takes it.
        #expect(try PushDelivery.item(Recorded.payload(Recorded.gone), opener: RemoteKitPushOpener(), keys: { Recorded.keys }, now: now)
            == .gone(needs: ["need-approval-1"]))
        let two = Recorded.seal(#"{"v":1,"type":"gone","needs":["n1","n2"],"at":1795392000000}"#, kind: .background, idByte: 0x50)
        #expect(try PushDelivery.item(Recorded.payload(two), opener: RemoteKitPushOpener(), keys: { Recorded.keys }, now: now) == .gone(needs: ["n1", "n2"]))
        // Each size: the smallest of 1,464 and 3,000 that holds the body, an alert never 696.
        #expect(PushBase64URL.decode(Recorded.gone)?.count == 696)
        for (characters, size) in [(10, 1_464), (300, 1_464), (600, 3_000)] {
            let sealed = Recorded.seal(Recorded.alert("pi2.limit", title: "Forge", body: String(repeating: "é", count: characters), type: "limit"), idByte: 0x51)
            #expect(PushBase64URL.decode(sealed)?.count == size)
            #expect(deliver(sealed, opener: RemoteKitPushOpener()).content.body.count == min(characters, PushItem.bodyLimit))
        }
    }

    @Test func aWrongKeyAReplayedPushAndACutOneAreRefused() throws {
        func refused(_ result: (content: UNNotificationContent, outcome: PushDelivery.Outcome), _ why: PushRefusal) {
            #expect(result.outcome == .placeholder(why))
            #expect(result.content.title == "pi²" && result.content.body == "Something needs you" && result.content.categoryIdentifier.isEmpty)
        }
        let opener = RemoteKitPushOpener()
        // A wrong key: another phone's record key, another Mac's identity, sealed for another device.
        let keys = Recorded.keys
        let stranger = P256.KeyAgreement.PrivateKey().rawRepresentation
        refused(deliver(Recorded.approval, opener: opener, keys: PushKeys(
            pairing: keys.pairing, device: keys.device, recordKey: stranger, macRecordKey: keys.macRecordKey, macIdentityKey: keys.macIdentityKey)), .doesNotOpen)
        refused(deliver(Recorded.seal(Recorded.alert("pi2.approval", title: "Forge needs approval", body: "ls"), identity: P256.Signing.PrivateKey()), opener: opener), .doesNotOpen)
        refused(deliver(Recorded.seal(Recorded.alert("pi2.approval", title: "Forge needs approval", body: "ls"), device: "dev_AwMDAwMDAwMDAwMDAwMDAw"), opener: opener), .doesNotOpen)

        // Replayed: the same push again, as a relay or anyone who recorded it could hand it back.
        let folder = FileManager.default.temporaryDirectory.appending(path: "push-seen-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let seen = PushSeen(folder: folder)
        func delivered(_ sealed: String, at time: Date) -> PushDelivery.Outcome {
            PushDelivery.deliver(Recorded.payload(sealed), opener: opener, keys: { Recorded.keys }, seen: seen, now: time).outcome
        }
        guard case .shown = delivered(Recorded.approval, at: now) else { Issue.record("the first time is shown"); return }
        #expect(delivered(Recorded.approval, at: now.addingTimeInterval(60)) == .placeholder(.replayed))
        guard case .shown = delivered(Recorded.question, at: now.addingTimeInterval(60)) else { Issue.record("another push is shown"); return }
        // A push that does not open is not remembered, so made-up pushes cannot fill the memory.
        var changed = try #require(PushBase64URL.decode(Recorded.approvalCut))
        changed[100] ^= 1
        _ = delivered(PushBase64URL.encode(changed), at: now)
        guard case .shown = delivered(Recorded.approvalCut, at: now.addingTimeInterval(60)) else { Issue.record("a push whose copy did not open is shown"); return }
        // After a day the push is refused for its age anyway; the memory lets its id go after 25 hours.
        #expect(delivered(Recorded.approval, at: now.addingTimeInterval(PushItem.oldest + 60)) == .placeholder(.tooOld))
        #expect(seen.firstTime(PushBase64URL.encode(Data(repeating: 0x0a, count: 16)), now: now.addingTimeInterval(PushSeen.keptFor + 1)))
        #expect(seen.firstTime("not-an-id", now: now), "an id of another shape names no file, and is not guarded")

        // Cut: shorter than a push's size, or cut and made up to one again.
        let whole = try #require(PushBase64URL.decode(Recorded.question))
        refused(deliver(PushBase64URL.encode(whole.prefix(680)), opener: opener), .wrongSize)
        refused(deliver(PushBase64URL.encode(whole.prefix(600) + Data(count: 96)), opener: opener), .doesNotOpen)
        refused(deliver(PushBase64URL.encode(whole.dropLast(16).prefix(600) + Data(count: 80) + whole.suffix(16)), opener: opener), .doesNotOpen)
    }

    // MARK: What a push says, once opened

    @Test func whatTheMacWroteIsShownOnOneLineAndHeldToItsLength() throws {
        let long = String(repeating: "x", count: 400)
        let (content, outcome) = deliver(Recorded.approval, opener: GivenOpener(kind: "push", body: [
            "v": 1, "type": "need", "category": "pi2.approval", "title": "Forge\nneeds approval\u{7}", "body": "rm\u{0}-rf \(long)", "whole": true, "at": 1,
        ]))
        #expect(content.title == "Forge needs approval")
        #expect(content.body.count == 180 && !content.body.contains("\u{0}"))
        // Cut here, so not whole whatever the Mac said: no Allow once.
        guard case let .shown(notice) = outcome else { Issue.record("not shown"); return }
        #expect(!notice.whole && content.categoryIdentifier == "pi2.approval.cut")
        #expect(content.threadIdentifier == PushNotice.noProject)
    }

    @Test func onlyJSONTrueMakesACallWhole() {
        let base: [String: Any & Sendable] = ["v": 1, "type": "need", "category": "pi2.approval", "title": "Forge needs approval", "body": "ls", "at": 1]
        for whole: (any Sendable)? in [nil, 1, "true", false] {
            var body = base
            if let whole { body["whole"] = whole }
            #expect(deliver(Recorded.approval, opener: GivenOpener(kind: "push", body: body)).content.categoryIdentifier == "pi2.approval.cut")
        }
        var whole = base
        whole["whole"] = true
        #expect(deliver(Recorded.approval, opener: GivenOpener(kind: "push", body: whole)).content.categoryIdentifier == "pi2.approval")
        // Part hidden by the Mac's masks: never Allow once, whatever `whole` says (7.1).
        whole["partHidden"] = true
        #expect(deliver(Recorded.approval, opener: GivenOpener(kind: "push", body: whole)).content.categoryIdentifier == "pi2.approval.cut")
    }

    @Test func everyKindHasItsCategoryAndAnUnknownOneNone() {
        for kind in PushKind.allCases {
            let content = deliver(Recorded.approval, opener: GivenOpener(kind: "push", body: [
                "v": 1, "type": "need", "category": kind.category, "title": "Forge", "body": "it", "whole": true, "projectId": "p", "at": 1,
            ])).content
            #expect(content.categoryIdentifier == kind.category)
        }
        let newer = deliver(Recorded.approval, opener: GivenOpener(kind: "push", body: [
            "v": 1, "type": "need", "category": "pi2.survey", "title": "Forge asks", "body": "Demo", "whole": false, "at": 1,
        ]))
        #expect(newer.content.title == "Forge asks" && newer.content.categoryIdentifier.isEmpty)
        // A push with no title, of another version, whose type is not its kind's, or of a kind of Mac item that is not a
        // notification, is not shown as the Mac wrote it.
        let notices: [(String, [String: Any & Sendable])] = [
            ("push", ["v": 1, "type": "need", "category": "pi2.approval", "body": "Demo", "at": 1]),
            ("push", ["v": 2, "type": "need", "category": "pi2.approval", "title": "x", "body": "y", "at": 1]),
            ("push", ["v": 1, "type": "gone", "needs": ["n1"], "at": 1]),
            ("pushGone", ["v": 1, "type": "need", "category": "pi2.approval", "title": "x", "body": "y", "at": 1]),
            ("state", ["v": 1, "type": "need", "title": "x", "body": "y", "at": 1]),
        ]
        for (kind, body) in notices {
            #expect(deliver(Recorded.approval, opener: GivenOpener(kind: kind, body: body)).outcome == .placeholder(.notANotice))
        }
    }

    // MARK: The categories

    @Test func theCategoriesAreSectionSevensTable() throws {
        let ids = Set(PushCategories.all.map(\.identifier))
        #expect(ids == [
            "pi2.approval", "pi2.approval.cut", "pi2.question", "pi2.question.cut", "pi2.decision", "pi2.reach",
            "pi2.rule", "pi2.rule.cut", "pi2.limit", "pi2.notice",
        ])
        #expect(try buttons("pi2.question.cut") == ["Open"])
        #expect(try buttons("pi2.decision") == ["Open"])
        #expect(try buttons("pi2.reach") == ["Allow…", "Refuse"])
        #expect(try buttons("pi2.rule") == ["Accept", "Refuse", "Open"])
        #expect(try buttons("pi2.rule.cut") == ["Refuse", "Open"])
        #expect(try buttons("pi2.limit") == ["Start anyway…", "Wait"])
        #expect(try buttons("pi2.notice") == [])
    }

    @Test func everyButtonOpensPiUnlockedAndNoneAnswersFromTheLockScreen() {
        for category in PushCategories.all {
            for action in category.actions {
                #expect(action.options.contains(.foreground), "\(action.identifier) opens pi²")
                #expect(action.options.contains(.authenticationRequired), "\(action.identifier) needs the phone unlocked")
                let destructive = action.identifier == "deny" || action.identifier == "refuse"
                #expect(action.options.contains(.destructive) == destructive)
            }
        }
    }

    @Test func theLockScreenShowsTheTitleAndAPlaceholderInPlaceOfTheBody() {
        for category in PushCategories.all {
            #expect(category.options.contains(.hiddenPreviewsShowTitle))
            #expect(!category.options.contains(.hiddenPreviewsShowSubtitle))
            #expect(category.hiddenPreviewsBodyPlaceholder.contains("Unlock"))
        }
    }

    @MainActor @Test func theDemoOffersTheSameButtons() {
        // The demo's notifications (#684) are to take their categories from here; until they do, they must agree.
        func table(_ categories: Set<UNNotificationCategory>) -> [String: [String]] {
            Dictionary(uniqueKeysWithValues: categories.map { ($0.identifier, $0.actions.map(\.identifier)) })
        }
        #expect(table(DemoNotifications.categories) == table(PushCategories.all))
    }

    @Test func theCategoriesRegisterWithTheNotificationCentre() async throws {
        let center = UNUserNotificationCenter.current()
        PushCategories.register(on: center)
        var registered: Set<UNNotificationCategory> = []
        // setNotificationCategories takes effect a moment later; wait for it, with a generous limit.
        for _ in 0..<200 {
            registered = await center.notificationCategories()
            if Set(registered.map(\.identifier)) == Set(PushCategories.all.map(\.identifier)) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(Set(registered.map(\.identifier)) == Set(PushCategories.all.map(\.identifier)))
    }

    /// Provisional authorization asks nothing (no prompt, in the simulator or on a phone), and lets `xcrun simctl push`
    /// deliver a notification to this app in the simulator, quietly: how #690 pictured one (docs/iphone-app.md, "The
    /// extensions"). The app itself asks for notifications at pairing (3.3 step 9), which is not built yet.
    @Test func aPushCanReachTheAppInTheSimulatorWithoutAPrompt() async throws {
        let center = UNUserNotificationCenter.current()
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            _ = try await center.requestAuthorization(options: [.provisional, .alert, .sound, .badge])
        }
        let status = await center.notificationSettings().authorizationStatus
        #expect(status == .provisional || status == .authorized)
    }

    // MARK: A button's response

    @Test func aButtonsResponseSaysWhichCardToOpen() {
        let content = deliver(Recorded.question).content
        let response = PushResponse(action: "reply", userInfo: content.userInfo, reply: "main")
        #expect(response == PushResponse(action: "reply", userInfo: [
            "need": "need-question-1", "kind": "question", "projectId": "project-demo-2", "conversationId": 139,
        ], reply: "main"))
        #expect(response.action == .reply && response.kind == .question && response.conversationId == 139 && response.reply == "main")
        #expect(PushResponse(action: UNNotificationDefaultActionIdentifier, userInfo: [:], reply: nil).action == nil)
    }

    // MARK: Taking a notification away

    @Test func aBackgroundPushNamesTheNeedWhoseNotificationGoes() throws {
        #expect(try PushDelivery.item(Recorded.payload(Recorded.gone), opener: CheckOpener(), keys: { Recorded.keys }, now: now)
            == .gone(needs: ["need-approval-1"]))
        let shown: [(String, [AnyHashable: Any])] = [
            ("a", deliver(Recorded.approval).content.userInfo), ("b", deliver(Recorded.question).content.userInfo), ("c", [:]),
        ]
        #expect(PushRemoval.identifiers(of: ["need-approval-1"], in: shown) == ["a"])
        #expect(PushRemoval.identifiers(of: [], in: shown).isEmpty)
    }

    // MARK: The extension's own file

    @Test func theExtensionsFileKeepsEachNoticeOnceForTheAppToTake() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "push-inbox-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let inbox = PushInbox(folder: folder)
        #expect(try inbox.take().isEmpty)
        for sealed in [Recorded.question, Recorded.approval, Recorded.approval] {
            guard case let .shown(notice) = deliver(sealed).outcome else { Issue.record("not shown"); return }
            try inbox.keep(notice)
        }
        #expect(try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        let entries = try inbox.take()
        #expect(entries.map(\.need) == ["need-approval-1", "need-question-1"])
        #expect(entries.first?.title == "Forge needs approval" && entries.first?.subtitle == "Demo project" && entries.first?.whole == true)
        #expect(try inbox.take().isEmpty)
        try inbox.wipe()
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        // One app group for the app and its extensions; an unsigned build has none, and keeps nothing.
        #expect(PushInbox.appGroup == WidgetsFile.appGroup && PushInbox.appGroup == ShareDrop.appGroup)
        #expect(PushInbox.shared == nil)
    }

    // MARK: The keys

    @Test func theExtensionReadsTheItemsKeysWritesUnderTheirNames() {
        #expect(PushKeychain.service == SystemKeychain.service)
        #expect(PushKeychain.recordKeyItem == KeyItem.recordKey.rawValue && KeyItem.recordKey.shared)
        #expect(PushKeychain.macRecordItem == KeyItem.macRecord.rawValue && KeyItem.macRecord.shared)
        #expect(PushKeychain.accessGroup == SystemKeychain.sharedAccessGroup)
    }

    @Test func theMacsRecordGivesTheKeysAPushOpensWith() throws {
        let record = try JSONSerialization.data(withJSONObject: [
            "pairing": Recorded.pairing, "device": Recorded.device, "name": "Test Mac",
            "identityKey": PushBase64URL.encode(Recorded.macIdentityKey.derRepresentation),
            "recordKey": PushBase64URL.encode(Recorded.macRecordKey.derRepresentation),
        ])
        let keys = try PushMacRecord.keys(recordKey: Recorded.phoneRecordKey, macRecord: record)
        #expect(deliver(Recorded.approval, keys: keys).content.title == "Forge needs approval")
        #expect(throws: PushRefusal.noKeys) { try PushMacRecord.keys(recordKey: Recorded.phoneRecordKey, macRecord: Data("{}".utf8)) }
    }

    @Test func anUnsignedBuildFindsNoKeysAndShowsThePlaceholder() {
        // The simulator's Keychain refuses an unsigned build (errSecMissingEntitlement), as the extension's would.
        let result = PushDelivery.deliver(Recorded.payload(Recorded.approval), opener: CheckOpener(), keys: { try PushKeychain().keys() }, now: now)
        #expect(result.outcome == .placeholder(.noKeys))
    }
}
