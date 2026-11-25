
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
            "console": Array(console.prefix(consoleLines)).map { cut($0, consoleLine) },
            "blocked": Array(findings.blocked.prefix(blockedAddresses)).map { cut($0, blockedAddress) },
        ]
        guard findings.ok, let snapshot = findings.snapshot, let fitted = fit(snapshot) else {
            var reason = findings.reason ?? (findings.ok ? "it loaded, but its picture could not be made" : "it could not be drawn")
            if findings.ok, findings.snapshot != nil { reason = "its picture is past 20 MB or 16,384 pixels a side and could not be made smaller" }
            params["ok"] = false
            params["reason"] = cut(([reason] + notes).joined(separator: "; "), reasonLength)
            return params
        }
        if fitted.scaled { notes.append("its picture was made smaller to fit 20 MB and 16,384 pixels a side") }
        params["ok"] = true
        params["loadMs"] = min(max(findings.loadMs, 0), 3_600_000)
        params["blank"] = findings.blank
        params["height"] = min(max(findings.height > 0 ? findings.height : asked, 1), 1_000_000)
        params["snapshot"] = ["mimeType": "image/png", "data": fitted.png.base64EncodedString()]
        if !notes.isEmpty { params["reason"] = cut(notes.joined(separator: "; "), reasonLength) }
        return params
    }

    /// A page that could not be drawn, and why.
    public static func failed(_ reason: String) -> [String: Any] {
        ["ok": false, "reason": cut(reason.isEmpty ? "it could not be drawn" : reason, reasonLength), "console": [String](), "blocked": [String]()]
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
