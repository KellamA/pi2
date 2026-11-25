import Foundation

/// Text an agent wrote, as a presentation's window shows it (docs/design/presenting.md, "What stops it looking like
/// pi²"): a title, a label, a caption, a conversation's title, the address a page tried to leave for. Always plain text,
/// drawn with `Text(verbatim:)` in a view of its own, never Markdown or an attributed string; on one line; cut to a
/// length; and without anything that could change how the text around it reads or is laid out:
///
/// - line breaks of every kind (`\n`, `\r`, U+2028, U+2029, U+0085) and tabs become spaces, so a title cannot add a line
///   that looks like the bar's ("Version 3 of 3 · network off");
/// - every other control character (C0, DEL, C1) goes;
/// - the bidirectional controls (U+202A–U+202E embeddings and overrides, U+2066–U+2069 isolates, U+200E, U+200F and
///   U+061C marks) go, so a title cannot turn the words after it around ("fdp.exe" read as "exe.pdf");
/// - zero-width characters (U+200B–U+200D, U+2060, U+FEFF) and the interlinear annotation marks (U+FFF9–U+FFFB) go,
///   which could hide one word inside another;
/// - runs of spaces become one, and the ends are trimmed;
/// - it is cut to `limit` characters (whole characters, as the person counts them), with "…" when it was longer.
///
/// What is left of a script written right to left is still drawn right to left, in its own text view, so it reads as
/// its writer meant and cannot reach the text beside it.
enum PresentationText {
    /// The longest each kind of text is drawn: the engine bounds a title to 120 and a caption to 400 already.
    static let title = 120
    static let label = 40
    static let caption = 400
    static let conversation = 80
    static let agent = 40
    static let address = 80

    static func plain(_ text: String?, limit: Int) -> String {
        guard let text, !text.isEmpty else { return "" }
        var out = String.UnicodeScalarView()
        var lastWasSpace = true
        for scalar in text.unicodeScalars {
            if breaks.contains(scalar.value) || CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true
                continue
            }
            if removed(scalar) { continue }
            out.append(scalar)
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
        switch scalar.value {
        case 0x00...0x1F, 0x7F...0x9F: true // controls
        case 0x202A...0x202E, 0x2066...0x2069, 0x200E, 0x200F, 0x061C: true // bidirectional embeddings, overrides, isolates, marks
        case 0x200B...0x200D, 0x2060, 0xFEFF: true // zero-width spaces and joiners, the word joiner, the byte order mark
        case 0xFFF9...0xFFFB: true // interlinear annotations
        default: false
        }
    }
}
