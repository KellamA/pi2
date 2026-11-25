import Foundation

/// Text someone other than pi² chose, as a presentation's window shows it (docs/design/presenting.md, "What stops it
/// looking like pi²"): an agent's title, labels and captions, a conversation's or a project's name (which an agent or any
/// process on the engine's socket can set), the address a page tried to leave for. Always plain text, drawn with
/// `Text(verbatim:)` in a view of its own, never Markdown or an attributed string; on one line; cut to a length; and
/// without anything that could change how the text around it reads or is laid out:
///
/// - line breaks of every kind (`\n`, `\r`, U+2028, U+2029, U+0085) and tabs become spaces, so a title cannot add a line
///   that looks like the bar's ("Version 3 of 3 · network off");
/// - every control character (C0, DEL, C1) and every format character goes: the bidirectional embeddings, overrides,
///   isolates and marks that turn the words after them around ("fdp.exe" read as "exe.pdf"), zero-width spaces and
///   joiners, the soft hyphen, invisible operators, tag characters, the interlinear annotation marks;
/// - variation selectors, private-use characters, the object replacement character and the Hangul fillers go, which draw
///   nothing or anything a font likes;
/// - at most two combining marks are kept on each character, so stacked marks cannot draw outside the line;
/// - runs of spaces become one, and the ends are trimmed;
/// - it is cut to `limit` characters (whole characters, as the person counts them), with "…" when it was longer.
///
/// A name (`name`) also loses every kind of quotation mark, a single one becoming a plain apostrophe, so that no name can
/// open or close quotation marks of the window's own. What is left of a script written right to left is still drawn right
/// to left, in its own text view, so it reads as its writer meant and cannot reach the text beside it.
enum PresentationText {
    /// The longest each kind of text is drawn: the engine bounds a title to 120 and a caption to 400 already.
    static let title = 120
    static let label = 40
    static let caption = 400
    static let conversation = 60
    static let project = 40
    static let agent = 30
    static let address = 80

    /// The most combining marks kept on one character.
    static let marks = 2

    static func plain(_ text: String?, limit: Int) -> String {
        clean(text, limit: limit, quotes: false)
    }

    /// A name someone chose: plain, and with no quotation marks.
    static func name(_ text: String?, limit: Int) -> String {
        clean(text, limit: limit, quotes: true)
    }

    private static func clean(_ text: String?, limit: Int, quotes: Bool) -> String {
        guard let text, !text.isEmpty else { return "" }
        var out = String.UnicodeScalarView()
        var lastWasSpace = true
        var stacked = 0
        for scalar in text.unicodeScalars {
            if breaks.contains(scalar.value) || scalar.properties.isWhitespace {
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true
                stacked = 0
                continue
            }
            if removed(scalar) { continue }
            if quotes, doubleQuotes.contains(scalar.value) { continue }
            if isMark(scalar) {
                // On nothing, or past the most kept on one character: dropped.
                if lastWasSpace || stacked >= marks { continue }
                stacked += 1
                out.append(scalar)
                continue
            }
            stacked = 0
            out.append(quotes && singleQuotes.contains(scalar.value) ? "'" : scalar)
            lastWasSpace = false
        }
        var plain = String(out)
        while plain.last == " " { plain.removeLast() }
        guard plain.count > limit else { return plain }
        var cut = String(plain.prefix(max(limit - 1, 1)))
        while cut.last == " " { cut.removeLast() }
        return cut + "…"
    }

    /// Line and paragraph breaks and tabs, which become a space.
    private static let breaks: Set<UInt32> = [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029]

    private static func removed(_ scalar: Unicode.Scalar) -> Bool {
        let properties = scalar.properties
        switch properties.generalCategory {
        case .control, .format, .privateUse, .surrogate, .unassigned: return true
        default: break
        }
        if properties.isVariationSelector { return true }
        switch scalar.value {
        case 0xFFFC, 0xFFFD: return true // object replacement, replacement character
        case 0x3164, 0x115F, 0x1160, 0xFFA0: return true // Hangul fillers, which draw as blanks
        case 0x180B...0x180F: return true // Mongolian free variation selectors and vowel separator
        default: return false
        }
    }

    private static func isMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: true
        default: false
        }
    }

    /// Quotation marks of every kind that a name loses: double ones go, single ones become an apostrophe.
    private static let doubleQuotes: Set<UInt32> = [
        0x22, 0xAB, 0xBB, 0x201C, 0x201D, 0x201E, 0x201F, 0x2033, 0x2036, 0x275D, 0x275E, 0x2E42, 0x301D, 0x301E, 0x301F,
        0x300C, 0x300D, 0x300E, 0x300F, 0xFE41, 0xFE42, 0xFE43, 0xFE44, 0xFF02, 0xFF62, 0xFF63, 0x1F676, 0x1F677, 0x1F678,
    ]
    private static let singleQuotes: Set<UInt32> = [
        0x27, 0x60, 0xB4, 0x2018, 0x2019, 0x201A, 0x201B, 0x2032, 0x2035, 0x2039, 0x203A, 0x275B, 0x275C, 0xFF07, 0xFF40,
    ]
}
