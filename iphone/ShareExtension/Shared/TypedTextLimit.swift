import Foundation

/// The most typed text a message or an answer from the phone carries (#924, the owner's decision): 1 MB of UTF-8, as
/// the engine counts it (`MAX_TYPED_FROM_A_DEVICE` and `typedRefusal` in engine/src/answers.ts), which refuses more from
/// a phone in these very words. The phone says so before it sends, so that what was typed stays where it was typed. The
/// Mac's own app has no such limit.
enum TypedTextLimit {
    static let bytes = 1024 * 1024

    /// Why `text` cannot go in one message (or, with `answer`, one answer) from the phone, in the engine's words, or nil
    /// when it can.
    static func refusal(_ text: String, answer: Bool = false) -> String? {
        let count = text.utf8.count
        guard count > bytes else { return nil }
        let size = sizeText(count) == sizeText(bytes) ? "just over 1 MB" : sizeText(count)
        return answer
            ? "An answer from a phone can carry at most 1 MB of typed text; this one has \(size). Shorten it, or answer on the Mac."
            : "A message from a phone can carry at most 1 MB of typed text; this one has \(size). Shorten it, or send it from the Mac."
    }

    /// A size of a megabyte or more as the engine writes one (`sizeText` in engine/src/attachments.ts): megabytes of
    /// 1,048,576 bytes to a tenth, a half rounded up, as JavaScript's `toFixed(1)` rounds.
    static func sizeText(_ bytes: Int) -> String {
        let tenths = (bytes * 10 + 524_288) / 1_048_576
        return "\(tenths / 10).\(tenths % 10) MB"
    }
}
