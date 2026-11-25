
import Foundation
import ImageIO
import PiModels

/// One `present.draw` as the engine sends it (docs/design/presenting.md, "Drawing a page: the engine asks the app"), read
/// by the app before anything is drawn: anything not shaped as the contract says is not drawn.
public struct PresentedDrawRequest: Equatable, Sendable {
    public let requestId: String
    public let conversation: Int
    public let presentation: String
    public let version: Int
    public let item: Int
    public let width: Int
    public let height: Int

    /// The size a page is drawn at, at least and at most: the engine asks 1280 by 800, and past this a picture would
    /// only be too large to send.
    static let sizes = 200...4096

    public init?(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let requestId = object["requestId"] as? String, (1...64).contains(requestId.utf8.count),
              let conversation = Self.whole(object["conversationId"]), conversation >= 0,
              let presentation = object["presentation"] as? String, PresentationRecord.isID(presentation),
              let version = Self.whole(object["version"]), version >= 1,
              let item = Self.whole(object["item"]), (0..<6).contains(item),
              let width = Self.whole(object["width"]), let height = Self.whole(object["height"]) else { return nil }
        self.requestId = requestId
        self.conversation = conversation
        self.presentation = presentation
        self.version = version
        self.item = item
        self.width = min(max(width, Self.sizes.lowerBound), Self.sizes.upperBound)
        self.height = min(max(height, Self.sizes.lowerBound), Self.sizes.upperBound)
    }

    private static func whole(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.rounded() == double, abs(double) < 9_007_199_254_740_992 else { return nil }
        return number.intValue
    }
}

/// What the app answers a `present.draw` with: `present.drawn`'s parameters, each within the contract's bounds
/// (engine/src/presented.ts, `LIMITS` and `checkDrawn`), so that the engine never refuses them for size: lines and
/// addresses cut, a snapshot too large scaled down to fit, and the reason saying so.
public enum PresentedDrawAnswer {
    public static let consoleLines = 50
    public static let consoleLine = 500
    public static let blockedAddresses = 20
    public static let blockedAddress = 2_048
    public static let reasonLength = 500
    public static let snapshotBytes = 20 * 1024 * 1024
    public static let snapshotSide = 16_384
    /// What the page tried that the contract has no field for, said in its console's lines before its own: so many of
    /// each at most, so that a page cannot push them out by logging more than the answer carries.
    static let ownLines = 10

    /// `present.drawn`'s parameters for what drawing found (without `requestId`). `asked` is the height drawn at, the
    /// page's height when it could not be read.
    public static func params(_ findings: PresentedPageFindings, height asked: Int) -> [String: Any] {
        var console = findings.answered.prefix(ownLines).map { "asked for and answered without anything shown: \($0)" }
        console += findings.notFound.prefix(ownLines).map { "not in the page's files, so not served: \($0)" }
        console += findings.console
        var notes: [String] = []
        if console.count > consoleLines { notes.append("\(console.count - consoleLines) more console lines were left out") }
        var params: [String: Any] = [
            "console": Array(console.prefix(consoleLines)).map { cut(plain($0), consoleLine) },
            "blocked": Array(blocked(findings).prefix(blockedAddresses)),
        ]
        guard findings.ok, let snapshot = findings.snapshot, let fitted = fit(snapshot) else {
            var reason = findings.reason ?? (findings.ok ? "it loaded, but its picture could not be made" : "it could not be drawn")
            if findings.ok, findings.snapshot != nil { reason = "its picture is past 20 MB or 16,384 pixels a side and could not be made smaller" }
            if plain(reason).trimmingCharacters(in: .whitespaces).isEmpty { reason = "it could not be drawn" }
            params["ok"] = false
            params["reason"] = cut(plain(([reason] + notes).joined(separator: "; ")), reasonLength)
            return params
        }
        if fitted.scaled { notes.append("its picture was made smaller to fit 20 MB and 16,384 pixels a side") }
        params["ok"] = true
        params["loadMs"] = min(max(findings.loadMs, 0), 3_600_000)
        params["blank"] = findings.blank
        params["height"] = min(max(findings.height > 0 ? findings.height : asked, 1), 1_000_000)
        params["snapshot"] = ["mimeType": "image/png", "data": fitted.png.base64EncodedString()]
        if !notes.isEmpty { params["reason"] = cut(plain(notes.joined(separator: "; ")), reasonLength) }
        return params
    }

    /// What is said after an address the page reported refused itself, rather than one the app saw refused.
    public static let pageReport = " (as the page reported it)"

    /// The addresses refused, as the agent is told them: only those that read as an address (`address`), each of
    /// 2,048 characters at most, those the page reported itself marked as its own report. The page can raise its own
    /// security-policy events, and change what reports them, so what it reports is believed only as far as it reads as
    /// an address, and is said to be its own.
    static func blocked(_ findings: PresentedPageFindings) -> [String] {
        let seen = Set(findings.blockedSeen)
        var out: [String] = []
        for entry in findings.blocked {
            guard let shown = address(entry) else { continue }
            let line = seen.contains(entry) ? cut(shown, blockedAddress) : cut(shown, blockedAddress - pageReport.utf16.count) + pageReport
            if !out.contains(line) { out.append(line) }
        }
        return out
    }

    /// The schemes WebKit names alone when a security policy refuses a load by its scheme (`blockedURI`), and how a
    /// `data:` address is said (its content is the page's own text).
    static let bareSchemes: Set<String> = ["file", "data", "blob", "about", "filesystem"]

    /// An entry as an address, or nil if it does not read as one: a scheme WebKit names alone (`file`, `data`, `blob`,
    /// `about`, `filesystem`); or an absolute URL that Foundation parses, with nothing in it that is not printable or a
    /// space, a scheme of letters, digits, `+`, `-` and `.`, and a host, unless it is a `file:`, `about:` or `blob:` one.
    /// A `data:` address is said as `data`.
    static func address(_ entry: String) -> String? {
        let text = plain(entry)
        guard !text.isEmpty, text == entry else { return nil }
        // Its content is the page's own text: only that it was a data: address is said.
        if text.lowercased().hasPrefix("data:") { return "data" }
        guard !text.unicodeScalars.contains(where: { $0.properties.isWhitespace }) else { return nil }
        if bareSchemes.contains(text.lowercased()) { return text.lowercased() }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || "+-.".unicodeScalars.contains($0) }) else { return nil }
        if ["file", "about", "blob"].contains(scheme) { return text }
        guard let host = url.host(percentEncoded: true), !host.isEmpty else { return nil }
        return text
    }

    /// Text with nothing in it that reads other than as it shows, as the engine's `unhidden` (engine/src/devices.ts)
    /// makes text a phone sent: a format character (a direction override or isolate, a zero-width or a tag character) is
    /// taken out, and a control character (C0, DEL and C1, such as U+009B) is a space; and, beyond `unhidden`, a line or
    /// paragraph separator (U+2028, U+2029) is a space too, since the agent's answer is lines of text.
    public static func plain(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .format, .surrogate: continue
            case .control, .lineSeparator, .paragraphSeparator: out.append(" ")
            default: out.append(scalar)
            }
        }
        return String(out)
    }

    /// A page that could not be drawn, and why.
    public static func failed(_ reason: String) -> [String: Any] {
        let reason = plain(reason).trimmingCharacters(in: .whitespaces)
        return ["ok": false, "reason": cut(reason.isEmpty ? "it could not be drawn" : reason, reasonLength), "console": [String](), "blocked": [String]()]
    }

    /// Text cut to at most `most` UTF-16 units, as the engine counts a string's length, never inside a character, with
    /// an ellipsis where it was cut.
    public static func cut(_ text: String, _ most: Int) -> String {
        guard text.utf16.count > most else { return text }
        var kept = ""
        var units = 0
        for character in text {
            let length = character.utf16.count
            if units + length > most - 1 { break }
            kept.append(character)
            units += length
        }
        return kept + "…"
    }

    /// A PNG within the contract's bounds: as it is if it is, or scaled down until it is. Nil if it cannot be read, or
    /// still does not fit after eight tries.
    public static func fit(_ png: Data) -> (png: Data, scaled: Bool)? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        if png.count <= snapshotBytes, image.width <= snapshotSide, image.height <= snapshotSide { return (png, false) }
        var scale = min(1, Double(snapshotSide) / Double(max(image.width, image.height)))
        for _ in 0..<8 {
            let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let smaller = context.makeImage(), let data = encode(smaller) else { return nil }
            if data.count <= snapshotBytes { return (data, true) }
            scale *= 0.7
        }
        return nil
    }

    static func encode(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
