import CryptoKit
import Foundation
import Testing
import UserNotifications
@testable import pi2

// The notification service extension's logic, in `iphone/Sources/Push/` (docs/iphone.md section 7, #690): opening a
// sealed push and verifying it, always replacing the text, the category and its buttons, the thread, the Lock Screen's
// placeholders, the extension's own file and taking a notification away. `xcrun simctl push` does not run the service
// extension in an unsigned build (docs/iphone-app.md "The extensions"), so it is tested here.
//
// The sealed pushes below were recorded with RemoteKit itself (`MacItem.make` and `SealedItem.seal`, compiled with a
// program of #690's), under test keys nobody holds: they are sample values, for these tests only. RemoteKit is not
// linked into the app or its tests yet, so they are opened here by `CheckOpener`, an opening worked out apart with
// CryptoKit as docs/remotekit.md describes the bytes; once RemoteKit is linked, the test under `canImport(RemoteKit)`
// opens them with RemoteKit's own opener too, which the extension then uses.

// MARK: Recorded pushes

enum Recorded {
    // Test keys: the phone's record key is 32 bytes of 0x11, the Mac's record key 0x22, its identity key 0x33.
    static let phoneRecordKey = Data(repeating: 0x11, count: 32)
    static let macRecordKey = try! P256.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x22, count: 32)).publicKey
    static let macIdentityKey = try! P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x33, count: 32)).publicKey
    static let pairing = "AQEBAQEBAQEBAQEBAQEBAQ"
    static let device = "dev_AgICAgICAgICAgICAgICAg"
    /// When they were signed: 2026-11-23, 00:00 UTC.
    static let at = Date(timeIntervalSince1970: 1_795_392_000)

    static let keys = PushKeys(
        pairing: pairing, device: device, recordKey: phoneRecordKey,
        macRecordKey: macRecordKey.derRepresentation, macIdentityKey: macIdentityKey.derRepresentation)

    /// `push`, an approval shown whole: "Forge needs approval", "Demo project · bash: npm test". 696 bytes.
    static let approval = "CgoKCgoKCgoKCgoKCgoKCgTeJJAkokPZ40dZRkjcZl49Z20PQKo-eZrJ6SRRw2O1n1-6WzCAVyCU-2L6XT-NVJk59SEyY4JSJcr9oSzS8pQ2Ew1ZSMK_8LTnxc7IlAtHIsilHuIYM8E1kUCLm6nE4xUHuk1oh8Wt0zQag0uIJ4zoS9ND9VdDoQHT7VUVMNZ97U6Ns4-LsG_n4c4vNZROVD989G8_oOPaMC5-b1v2w--O7ac-CjyP1rgyrMHwNrG603fHezpK8VnRvpObaAQcxLa06lRP02lehYhCpgIUMDIx-LabbaK1Ufcq4WPtZeIqCvB_vL2J_YVacuH7GVH57y6j2qLAs5H1I8KiJ1sXSqG04aSHVTGRd70OE2sO6RFnFRLlLremaQ4CayYflP5-KoxDWedtn1_Sr4ejnInsGWAapYcq0-oRj6bDTEYiRQXpc7XidOt3r7wWoyIwubfFW1i8K5mmpV_476il0zTyK73laYO3j_uBIrFBasutiI7qEQcLSDQ3IoCLS6vZzUg8KK8LuFUnfB2-6UO-NLe3wBGxA6met9COAtIfH1tPI7UcGJLDeA9ivHWYYKK3LU2iENz_ZdgXvdVvw1H2vr7PPz-au2l7rmbyfwH0-HjFD4yHY0UQkzuyhZhM1Xxa-wlfi4t2c5m0MCq4ihUlQC0gusghQS497NSnS_mCDuB7o9GtifO1KQSgjfDn0SfkdYUQDdEKiN-sJ2i9ofruSwnOxApubDopkeYVkSxQKETfRgf3NZA0VUZs5i5Bhac7iMbuT-e99t9d7gsnYXdlxjfIREaoTEw-iL3g_p23Se2Bsn3b2GDCRL30uykbGYAcd_JGYeK0A2kDaMa8KmNtVzQh9bK11xUG46NR4cJ3BOUnSBh8OkqmBXHBR9J9V5LWDNpvSUZNcjYq5vZb"
    /// `push`, an approval whose call was cut at 180 characters (`whole: false`). 1,464 bytes.
    static let approvalCut = "CwsLCwsLCwsLCwsLCwsLCwTlBUkDXGg_6br99UxH4GUsiXMyLMkGJDlJVUKUiGiba_7gaTbiMgamAOmaEKFyru3nj7mKb5Pvc2BPXslsUx0-bvPrtfkbAHMLXjmtnAAuWzccyyRasTuy5nIaPI-NyJqgArdKyM7J8SPZs3XwM5w9YQyG-1R6S6xCQI_6mAJN2ktTCwbzCrz3DidcZQDawBS0fgUNYi_FOPI_5n-GxHk2P82V_QsqHGdqIrkagLxvUBRvQXGfhcKwNQsMSw1_SG0sKbcJXOzSGmxFyP4oOXhEAjvuB_n2O6rpT07jAtYibI20hTREJEYp0dvZQbqgsWblCyBBBDQUjbVnfEiCVfWHDkUVowNpxwceSgx7YEwUQ0s8rGIJvP35IUWKSlHHNRjI2q_qW-fF7vT0nifrfAOZRvL1JDm8c1rdFPs7Sey6vyG1jv06SnWp8eIckEhHXTlk76ivtZ_DBPYVcgMZ_aNPlAO_Th4DSA1xnpSo0D4Q67b45jF6jO__eB1FUr-51wL6YePZVXGXCWTFqB_A2vliYYuxSl3Bw_F3Ah_sAYlcwBU9hkY7oouEyuhgzl1mvPuIQfOgnfVD5PxnpMH_u87Bkt1PEemnmNu5Fk2L-9WDVt-B8D_IO44-ShsoJAR-c_q9OPD33awlEWIKNKjjIyUKejmyrOB6ZPwC5FSQcv1cg4KKxK0aGv375ne_AvG71DEfQyVr4ROHzWfeei6DjUFdXVVJeMw6dwaX_sUBHKbwWiCfrJVDIlxVUhEadytwR4YNSHARrnFzPDfXQzK75tGmGZ4pzGfVA90rXmdnGzGUpyxPeHR21l8Pwt1Re0WXH3WVYBQ5OTWWZY8U237bQ_TBKT7PqABBXiqnJ6BYOoiqvlzCgCkZ_-S2S6UACOxTjgL7Ui5qtBI_vwqt8f-fCTNEXmprfrLEUfv2C6wOiHy2FjfiWc5qObx_aVaquj8Hbz5JI3DQOP7VFi7s9ciBdITNy_3XAk_ESOdvLd0qrF17fNCG-s-mL7F6EzN4AbOJTtsIWzRM2UTkAi-Kfx0M0qJpXx8Eu0lxnb_decvz8jLJbQSWWVVwU61ODNzOTW13tvO1fSJRH4aP-mqm9MkouhCNmy22ow0QeUPxWXRV575G88EWdQuLvYhCflpKZ7vH8ky_6sqeGq7AEJFBtiv_FUraMcdu5OcE-rHUuVyDXC9VdXmXnTkaIcRvltUJ8zv1UPrQeeZ_npZrXT8-3_hr4buMMPRz9AOf1QO6p0ZME4iiQFozyzy1VtIvYvRoQlumXcJ12ogmCuF6e5JfD8SWRA8q3-YTaRlpc3asOWVIUhhY88E-qY9L-lm3Xx6v2-SYngweiLaV2SkDua2Mhy-Isj41x17IvoCc0SU638DhIPInJNAk7seQUTq1kcVxHjogG5FSnkYF8jB76XFWCpn5me9-BzQhX-UAoKRiLDB3Vh1ce5fnpufW-vvhUCTPS23YQwTh5FqUo4Sezds__8Q6_YF0ovNMQu6bs8OZdiKQqtnLXdEZAXaZ0VsLfX20PCMb7uIVsYlh0iGD_JnTKNUScnZHtxqXvuc63l7uyjU1FYoInzJ2r6nUG0jDqNOOS4oqB7xJM_q_PPsFxeGIXy6mlqjv5N4fs5wFY3gED5OEaSsKIzUQmBUNglyNfs_MlBeN_AyJ2xECHyT09rMt1iS3R-Iw9azqO312WU6vFdqWj779lhO0PsJhh9wM19Ef7HgO3boyMcZjdEoJP3CWZM9J5k4KYF9x6V5cyjffBzmCBYuZ7wIS8aC6AsvQW7r0s_Ciixv0VTUfi4Fc-njlatI7zM9R4bPq-NX5yiaMVx6LcnTnbWHvnSZ56B9Yxt9JsPfG0jn4Yy_ceVQ_PORpWNopS_gARu2XeAnEyeSures33YX-kQ436QYtt-p_6ov0-ZMb6mnS49buT23h"
    /// `push`, a question: "Scribe has a question", in Demo project 2. 696 bytes.
    static let question = "DAwMDAwMDAwMDAwMDAwMDARbkAZHpAMvinm5OusG8l1s7g4Z1VguX70fhnySeqfbBYBt3lNoCFfdEnd8uT3e5qa-D9F0qbRGwIkHHNNzZLSYeBbPdtcmo-y2VJY3u8NKfm-sPTpihhvQR9qmHPcmQvvg-F5ysTDlJyBisqj1wU0X3V9VFXgGgZuT_k0d_Vt01vLIWLV3emxYyti-AH-TYJu03feavCOpkkXB0-bEzX5mBcFTBp5eq3G_8inHScj3cYxnaX_hGdHsIhDArr7tIH-6AyVz3wNlZAcmj9-WvrSGp8HiQXTiQRKwf5ddJMb68AE_x_X5lyedQxfUyObgMYJXd3gDLpu1CamY4XbjnkWaGJX10lSAkI-3t7o3T_DaHIMrfLoT_mzR3omc6HQrkjVzLvFxuRfse92u5yptxGw8wwanNkY1uSJR97yRscKEBePvu-sbDru4dnLClrrZtcmVHCpyRXL2O13sWxvUZsPbMgT2gu9gMq-bJjRlnsxMPHu4z9gTVif1v0EDTdFgNTZrOJGTW80CQOgUOltd06pMl43UvAaUP-sjZ2gpndIvQ5y0UCtL615Dx6E6FfcCMGrt4xmldeH0F7WQ6CcSxfOzedtMp7b1gVTELr7Tgey3F7B__8ezjtRUHCbn7NJR-cNoKXWg2MXz9lVgpMRMIbLprTTonvKOr09UcLRLQWydsO6mm0Ph5lUIUEaIT5VRljWzzj5hCfhQqR_tVi8eJfm3ADLzderD8pkWb-3l1YwT8eTFEpHbHrz2zkYY9dAFtQBvSmQ_W0QV3NTu3cQFvnc97uX74ugYSmB3f215wqgltA7xbT3Dl2t65Mjl2q5T64r788_npWILMfNdFgPH8XJ00vE8B2s0EQ2N_Kk28vzreO5uEUssagxpM5Y739nSR-j2Z83uxTvs"
    /// `pushGone`, the background push that takes the approval's notification away. 696 bytes.
    static let gone = "DQ0NDQ0NDQ0NDQ0NDQ0NDQSUPJ5c5exicTa-tTvr7ZVkuHOTrUEExu0EX1cFk3bEgbcl80TOmSAgMvw7lYEYIRe4GqeR_36FGYZdj1pgJcuEDybTnY2xGtu9fr7XR0DbRe0Bg866UnaszIvP13T-7CFv4x0VnhXkh8Agv3xIIOwCzx-UgjKSLQSAJzMfeG4xhQBB1iCaKkj44JEFXVRZ7QS35anFyanw1DaRiBNdVF80Y-g93u9omoN0_8b0RJuMPHkwKdy3FoL8s-_VSBRxbyt9_n9y49Hx0Ly5MECoC6Wi0hAitMWDdcXSwdvPzPYArccwnOmX7ZbWssn2GV6AtvWGJzCY5bgJK6b_sG4b35VheqZBT-Tu38mpHQ74GRytjS3ChAMqgL8MAVpkGKT1RSZ0g2xjicYCpWFMztb3ROHho8vIrtfgIi15JYveQ2rkv6K1byvdn_lx3HON6i-RD2MGWsEUGTHcD84gN6ygXuCJdsWXQNLwjg73lKDPNEdrsTGF9vW-qoufi3F_7aPW19E1daIzf31D-y9rZmgMwTsjIxXEOqFojzdnw1KTQDeIw-k43evSRl179eCAh-i3y04OJTnKLRoSkNRBri6Ebxu3OM3RgsdAZTzpsElmNHqUgSDVrN-8lFUVqjlK2EO3DzHpSvlkWdSzBtRCYYcoKKXFeLSqLFnqdp2FSpidC2GnO8kUAQZO3CbMnRmQM35QnNk3Ng8YjqIG7fnoRvY9K80Tg8jB8BAuli4Zn47xLtj3ELpubADvGNSUPD8f5aBpfpuuNGy9EJfRKsq-ARt7Vy6FHZRLkHQgfJOreu46ZV9c2a5tkaqROd7k6vd_nroM3SBxrQ8z7te-OxXOW8knS6T7qRK2sl-zDwiDRapsDyqH7y9cfhVL9rxnbA5Y14TixyQ71rlee6Zf"

    /// The payload Apple hands the phone, as the relay posts it.
    static func payload(_ sealed: String) -> [AnyHashable: Any] {
        ["aps": ["alert": ["title": "pi²", "body": "Something needs you"], "mutable-content": 1], "sealed": sealed]
    }
}

// MARK: Stand-ins

/// Opens a sealed push as docs/remotekit.md says the bytes are, worked out apart from RemoteKit with CryptoKit: HPKE's
/// authenticated mode with `info` = "pi2-item-v2", 0, the pairing, 0, the reader, 0, the item's id; then `{"v":2,
/// "signed":…,"signature":…}`, the identity key's signature over the exact `signed` text, and `signed`'s pairing, device
/// and nonce. Only the checks the bytes need; RemoteKit's own strict reading is RemoteKit's checks'.
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
              let kind = statement["kind"] as? String, let at = statement["at"] as? Int64, let body = statement["body"]
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
        #expect(content.body == "Demo project · bash: npm test")
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
        #expect(content.body == "Demo project 2 · Which branch should the release notes go on?")
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
        placeholder(deliver(PushBase64URL.encode(question.prefix(16) + approval.dropFirst(16))), .doesNotOpen)

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

    // MARK: What a push says, once opened

    @Test func whatTheMacWroteIsShownOnOneLineAndHeldToItsLength() throws {
        let long = String(repeating: "x", count: 400)
        let (content, outcome) = deliver(Recorded.approval, opener: GivenOpener(kind: "push", body: [
            "kind": "approval", "title": "Forge\nneeds approval\u{7}", "body": "Demo · rm\u{0}-rf \(long)", "whole": true,
        ]))
        #expect(content.title == "Forge needs approval")
        #expect(content.body.count == 180 && !content.body.contains("\u{0}"))
        // Cut here, so not whole whatever the Mac said: no Allow once.
        guard case let .shown(notice) = outcome else { Issue.record("not shown"); return }
        #expect(!notice.whole && content.categoryIdentifier == "pi2.approval.cut")
        #expect(content.threadIdentifier == PushNotice.noProject)
    }

    @Test func onlyJSONTrueMakesACallWhole() {
        for whole: (any Sendable)? in [nil, 1, "true", false] {
            var body: [String: Any & Sendable] = ["kind": "approval", "title": "Forge needs approval", "body": "Demo · ls"]
            if let whole { body["whole"] = whole }
            #expect(deliver(Recorded.approval, opener: GivenOpener(kind: "push", body: body)).content.categoryIdentifier == "pi2.approval.cut")
        }
    }

    @Test func everyKindHasItsCategoryAndAnUnknownOneNone() {
        for kind in PushKind.allCases {
            let content = deliver(Recorded.approval, opener: GivenOpener(kind: "push", body: [
                "kind": kind.rawValue, "title": "Forge", "body": "Demo · it", "whole": true, "projectId": "p",
            ])).content
            #expect(content.categoryIdentifier == kind.category)
        }
        let newer = deliver(Recorded.approval, opener: GivenOpener(kind: "push", body: ["kind": "survey", "title": "Forge asks", "body": "Demo"]))
        #expect(newer.content.title == "Forge asks" && newer.content.categoryIdentifier.isEmpty)
        // A push with no title, or of a kind of Mac item that is not a notification, is not shown as the Mac wrote it.
        #expect(deliver(Recorded.approval, opener: GivenOpener(kind: "push", body: ["body": "Demo"])).outcome == .placeholder(.notANotice))
        #expect(deliver(Recorded.approval, opener: GivenOpener(kind: "state", body: ["title": "x", "body": "y"])).outcome == .placeholder(.notANotice))
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
            == .gone(need: "need-approval-1"))
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
        #expect(entries.first?.title == "Forge needs approval" && entries.first?.whole == true)
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
