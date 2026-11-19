import AppKit

/// Text copied by pi²'s own buttons and menu items, rather than by the system's text selection.
@MainActor
enum AppCopy {
    enum Kind: String {
        case transcript, message, branchName, signInCode, filePath
    }

    static func write(_ text: String, kind: Kind, engine: EngineClient, conversation: Int? = nil) {
        #if PI2_DEVELOPMENT
        if let home = TestCopyControl.home(engine: engine) {
            let file = home.appendingPathComponent("copies.jsonl")
            // A failed record is not a reason to fall back to the person's pasteboard.
            guard (try? home.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
                  (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return }
            let scalars = text.unicodeScalars
            let length = scalars.count
            let limit = 4096
            var entry: [String: Any] = ["kind": kind.rawValue, "length": length]
            entry["conversation"] = conversation
            if length <= limit {
                entry["text"] = text
            } else {
                entry["prefix"] = String(scalars.prefix(limit))
            }
            TestCopyRecord.append(entry, to: file)
            return
        }
        #endif
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
