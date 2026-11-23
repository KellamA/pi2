import Foundation

// Built into both the app and the notification service extension (docs/iphone-app.md, "The extensions"): what the two
// must agree on about a push, from the bytes the relay hands Apple to the notification iOS shows (docs/iphone.md
// section 7). Only Foundation, the system's frameworks and PiModels here, and the other files of this folder.

/// A push's one custom key, `sealed`, as the relay posts it (relay/README.md, "Pushes"): base64url without padding,
/// exactly 696, 1,464 or 3,000 bytes once decoded, so that its size tells nothing but its class (section 7).
///
/// What those bytes hold is the sealer's (#689, pi² Remote's push part, not built yet), and this is what the phone
/// reads, as #690 assumed it: the item's 16-byte id, then the item exactly as RemoteKit seals a Mac item for the
/// mailbox (`SealedItem`, docs/remotekit.md "Sealed items": HPKE's encapsulated key, then the ciphertext), with the
/// padding inside the seal, as a `pad` member of the signed body, so that nothing outside it can be changed unseen.
/// The id goes in front because HPKE's `info` binds the item to it and the push carries nowhere else to say it.
struct SealedPush: Equatable, Sendable {
    /// The sizes a sealed push may have, in bytes.
    static let sizes = [696, 1_464, 3_000]
    static let idLength = 16

    /// The item's id, its 16 bytes.
    let id: Data
    /// The sealed item: HPKE's encapsulated key, then the ciphertext.
    let item: Data

    /// The item's id as RemoteKit writes it, base64url.
    var idText: String { PushBase64URL.encode(id) }

    /// Reads `sealed` from a push's payload (`userInfo`); throws if it is missing or not of the form above.
    static func read(_ userInfo: [AnyHashable: Any]) throws -> SealedPush {
        guard let text = userInfo["sealed"] as? String else { throw PushRefusal.noSeal }
        return try read(text)
    }

    static func read(_ text: String) throws -> SealedPush {
        guard let bytes = PushBase64URL.decode(text) else { throw PushRefusal.notBase64URL }
        guard sizes.contains(bytes.count) else { throw PushRefusal.wrongSize }
        let start = bytes.startIndex
        return SealedPush(id: Data(bytes[start..<(start + idLength)]), item: Data(bytes[(start + idLength)...]))
    }
}

/// Why a push was not shown as the Mac wrote it, in fixed words: what the extension's log may say, never a key or
/// anything from inside the seal.
enum PushRefusal: Error, Equatable, Sendable {
    case noSeal, notBase64URL, wrongSize
    /// This build has nothing to open a seal with (RemoteKit is not linked into it yet).
    case noOpener
    /// The phone has no keys for a Mac: not paired, or the Keychain cannot be read (an unsigned build, or locked
    /// since it started).
    case noKeys
    /// It does not open for this phone's keys, or the Mac's identity key did not sign it for this pairing, device and id.
    case doesNotOpen
    /// It opened and verified, but what it holds is not a notification as section 7 says.
    case notANotice
    /// It is more than a day old: the relay or anyone else could be handing back an old one.
    case tooOld

    var words: String {
        switch self {
        case .noSeal: "no sealed content"
        case .notBase64URL: "sealed content not base64url"
        case .wrongSize: "sealed content of a size no push has"
        case .noOpener: "this build cannot open sealed content"
        case .noKeys: "no keys for a Mac"
        case .doesNotOpen: "does not open or verify"
        case .notANotice: "not a notification"
        case .tooOld: "more than a day old"
        }
    }
}

/// base64url without padding, as RemoteKit writes it (docs/remotekit.md "Everywhere"): one way of writing given bytes,
/// so a reader takes nothing else.
enum PushBase64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ text: String) -> Data? {
        guard text.utf8.allSatisfy({ $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: "_") || (0x30...0x39).contains($0)
            || (0x41...0x5a).contains($0) || (0x61...0x7a).contains($0) }) else { return nil }
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        // Writing it again must give the same text: no padding, and the unused bits of the last character zero.
        guard let data = Data(base64Encoded: base64), encode(data) == text else { return nil }
        return data
    }
}
