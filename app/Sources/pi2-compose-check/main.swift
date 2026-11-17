// Checks what Return does in a field that sends a message (#174): Return sends, Shift-Return and Option-Return start
// a new line, and Return while an input method is composing is left to it.
//
// First ComposeKit's decision, for every combination of modifier keys, with and without an input method composing
// and with the key held down. Then a real SwiftUI text field, made as the app's message field is, in a window of this
// program's own that never comes on screen: key presses are handed straight to that window, so nothing is posted to
// the system, no other app sees them, and no permission is needed. It checks that Return sends, that Shift-Return and
// Option-Return put a line break at the cursor in place of the selection and the field grows, that Return with
// marked text (what an input method shows while composing) does not send, and that pasted line breaks are kept.
// Last, the same for the answer field of a question on the conversation page, a web page with its own copy of the
// rule, loaded from `Web/transcript` (run it from `app/`, or pass `--page <folder>`).
//
//   cd app && swift build --product pi2-compose-check && .build/debug/pi2-compose-check
//
// What it cannot do is type with a real input method, or press keys the way a person does: those are left to a try
// by hand. Exits 1 if anything failed.

import AppKit
import ComposeKit
import SwiftUI

setlinebuf(stdout)

nonisolated(unsafe) var failures = 0
func check(_ name: String, _ holds: Bool, _ detail: @autoclosure () -> String = "") {
    if holds { return }
    failures += 1
    let more = detail()
    print("FAIL  \(name)" + (more.isEmpty ? "" : "\n      " + more))
}

func group(_ name: String, _ body: () -> Void) {
    let before = failures
    body()
    print(failures == before ? "ok    \(name)" : "FAIL  \(name): \(failures - before) failed")
}

@MainActor
func group(_ name: String, _ body: () async -> Void) async {
    let before = failures
    await body()
    print(failures == before ? "ok    \(name)" : "FAIL  \(name): \(failures - before) failed")
}

// MARK: - The decision

group("the decision for every combination of modifier keys") {
    let all: [(String, EventModifiers)] = [("Shift", .shift), ("Option", .option), ("Control", .control), ("Command", .command)]
    for mask in 0..<16 {
        var held: EventModifiers = []
        var names: [String] = []
        for (bit, (name, flag)) in all.enumerated() where mask & (1 << bit) != 0 {
            held.insert(flag)
            names.append(name)
        }
        let label = (names + ["Return"]).joined(separator: "-")
        // Keys the decision ignores make no difference.
        for extra in [EventModifiers(), .capsLock, .numericPad, [.capsLock, .numericPad]] {
            for repeating in [false, true] {
                let action = ReturnKey.action(modifiers: held.union(extra), composing: false, repeating: repeating)
                let expected: ReturnKeyAction
                if held.isEmpty { expected = repeating ? .nothing : .send }
                else if held.isSubset(of: [.shift, .option]) { expected = .newLine }
                else if held.contains(.command) { expected = .leave }
                else { expected = .nothing }
                check("\(label)\(repeating ? " held down" : "")\(extra.isEmpty ? "" : " with \(extra.rawValue)")", action == expected, "got \(action), expected \(expected)")
                let composing = ReturnKey.action(modifiers: held.union(extra), composing: true, repeating: repeating)
                check("\(label) while composing", composing == .leave, "got \(composing), expected leave")
            }
        }
    }
    check("Return sends", ReturnKey.action(modifiers: [], composing: false, repeating: false) == .send)
    check("Shift-Return starts a new line", ReturnKey.action(modifiers: .shift, composing: false, repeating: false) == .newLine)
    check("Option-Return starts a new line", ReturnKey.action(modifiers: .option, composing: false, repeating: false) == .newLine)
    check("Return while composing is the input method's", ReturnKey.action(modifiers: [], composing: true, repeating: false) == .leave)
    check("keypad Enter counts as Return", ReturnKey.keys.contains(KeyEquivalent("\u{03}")) && ReturnKey.keys.contains(.return))
}

// MARK: - A real field

@MainActor @Observable
final class Draft {
    var text = ""
    var sent: [String] = []
}

/// Made as the conversation's message field is: vertical, growing to ten lines, sending with Return. `old` makes it
/// as it was before #174, sending with `onSubmit`, to show that keys handed to the window behave as a person's do.
struct Field: View {
    @Bindable var draft: Draft
    let old: Bool

    var body: some View {
        let field = TextField("Message", text: $draft.text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 13.5))
            .lineLimit(1...10)
        Group {
            if old { field.onSubmit(send) } else { field.sendsOnReturn(send) }
        }
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
    }

    private func send() {
        guard !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft.sent.append(draft.text)
        draft.text = ""
    }
}

@MainActor
final class Live {
    let draft = Draft()
    let window: NSWindow
    var editor: NSTextView? { window.firstResponder as? NSTextView }

    init(old: Bool = false) {
        // Far off every screen and never ordered in: the field works without being seen.
        window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 360, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Field(draft: draft, old: old))
    }

    func field(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for child in view.subviews { if let found = field(in: child) { return found } }
        return nil
    }

    func settle() async { try? await Task.sleep(for: .milliseconds(120)) }

    /// Presses Return with the given modifiers, handing the key down straight to the window, as AppKit would.
    func press(_ modifiers: NSEvent.ModifierFlags = [], keypad: Bool = false, repeating: Bool = false) async {
        let characters = keypad ? "\u{03}" : "\r"
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: keypad ? modifiers.union(.numericPad) : modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: repeating, keyCode: keypad ? 76 : 36)!
        window.sendEvent(event)
        await settle()
    }

    /// Puts text in the field, with the cursor (or a selection) where `cursor` says.
    func set(_ text: String, cursor: NSRange) async {
        draft.text = text
        await settle()
        editor?.setSelectedRange(cursor)
    }

    var height: CGFloat { field(in: window.contentView!)?.frame.height ?? 0 }

    /// Gives the field the keyboard, and says whether it took it.
    func focus() async -> Bool {
        await settle()
        guard let field = field(in: window.contentView!) else {
            check("the field is made", false, "no editable text field in the window")
            return false
        }
        window.makeFirstResponder(field)
        await settle()
        guard editor != nil else {
            check("the field takes the keyboard", false, "first responder is \(String(describing: window.firstResponder))")
            return false
        }
        return true
    }

    /// The field as it was: Shift-Return sent. Not a failure if it no longer does (a later macOS may change
    /// `onSubmit`), but then this check no longer shows that it would catch the old behaviour.
    func baseline() async {
        guard await focus() else { return }
        await set("hello", cursor: NSRange(location: 5, length: 0))
        await press(.shift)
        if draft.sent == ["hello"] {
            print("ok    a field sending with onSubmit sends on Shift-Return, as #174 found: the key presses here reach a field as a person's do")
        } else {
            print("note  a field sending with onSubmit no longer sends on Shift-Return here (sent \(draft.sent), text \(draft.text.debugDescription))")
        }
    }

    func run() async {
        guard await focus() else { return }

        await group("Shift-Return and Option-Return start a new line") {
            await set("hello world", cursor: NSRange(location: 5, length: 0))
            let oneLine = height
            await press(.shift)
            check("Shift-Return puts a line break at the cursor", draft.text == "hello\n world", "text is \(draft.text.debugDescription)")
            check("Shift-Return does not send", draft.sent.isEmpty, "sent \(draft.sent)")
            check("the cursor is after the line break", editor?.selectedRange() == NSRange(location: 6, length: 0), "selection is \(String(describing: editor?.selectedRange()))")
            check("the field grows", height > oneLine, "height \(height), one line \(oneLine)")

            await set("hello world", cursor: NSRange(location: 6, length: 5))
            await press(.option)
            check("Option-Return replaces the selection with a line break", draft.text == "hello \n", "text is \(draft.text.debugDescription)")
            await press([.shift, .option])
            check("Shift-Option-Return starts a new line too", draft.text == "hello \n\n", "text is \(draft.text.debugDescription)")
            await press(.shift, repeating: true)
            check("Shift-Return held down keeps starting lines", draft.text == "hello \n\n\n", "text is \(draft.text.debugDescription)")
            check("none of them sent", draft.sent.isEmpty, "sent \(draft.sent)")
            await press(.shift, keypad: true)
            check("Shift-Enter on the keypad starts a new line", draft.text == "hello \n\n\n\n", "text is \(draft.text.debugDescription)")
        }
        await group("Return while an input method is composing does not send") {
            await set("konnichiha ", cursor: NSRange(location: 11, length: 0))
            // What an input method does while a candidate is being chosen: marked text at the cursor.
            editor?.setMarkedText("こんにちは", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            await settle()
            check("the text is marked", editor?.hasMarkedText() == true)
            await press()
            await press(.shift)
            check("Return and Shift-Return while composing do not send", draft.sent.isEmpty, "sent \(draft.sent)")
            editor?.unmarkText()
            await settle()
        }
        await group("Return sends, and only Return") {
            draft.sent = []
            await set("first line\nsecond line", cursor: NSRange(location: 22, length: 0))
            // Command-Return is left to the field (it is the composer's shortcut for its Send button), and Control-Return
            // is swallowed, where the field on its own would type a space.
            for (name, modifiers) in [("Control", NSEvent.ModifierFlags.control), ("Command", .command), ("Control-Shift", [.control, .shift]), ("Control-Option", [.control, .option])] {
                await press(modifiers)
                check("\(name)-Return does not send", draft.sent.isEmpty, "sent \(draft.sent)")
                check("\(name)-Return leaves the text alone", draft.text == "first line\nsecond line", "text is \(draft.text.debugDescription)")
            }
            await press()
            check("Return sends the message with its line breaks", draft.sent == ["first line\nsecond line"], "sent \(draft.sent)")
            check("the field is empty after sending", draft.text.isEmpty, "text is \(draft.text.debugDescription)")
            await set("again", cursor: NSRange(location: 5, length: 0))
            await press(repeating: true)
            check("Return held down does not send", draft.sent.count == 1, "sent \(draft.sent)")
            await press(keypad: true)
            check("Enter on the keypad sends", draft.sent.last == "again", "sent \(draft.sent)")
        }
        await group("pasted line breaks are kept") {
            // Pasting reads the pasteboard into the selection. A pasteboard of this program's own leaves the person's alone.
            let board = NSPasteboard(name: NSPasteboard.Name("dev.pi2.compose-check.\(getpid())"))
            board.clearContents()
            board.setString("one\ntwo\n\nthree", forType: .string)
            await set("", cursor: NSRange(location: 0, length: 0))
            let pasted = editor?.readSelection(from: board) ?? false
            await settle()
            board.releaseGlobally()
            check("the paste is read", pasted)
            check("pasted text keeps its line breaks", draft.text == "one\ntwo\n\nthree", "text is \(draft.text.debugDescription)")
            await press()
            check("and is sent with them", draft.sent.last == "one\ntwo\n\nthree", "sent \(draft.sent)")
        }
    }
}

let app = NSApplication.shared
// No Dock icon, no menu bar, and never made active: the person's focus stays where it is.
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    let old = Live(old: true)
    await old.baseline()
    old.window.close()
    let live = Live()
    await live.run()
    live.window.close()
    let arguments = CommandLine.arguments
    let folder = arguments.firstIndex(of: "--page").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? "Web/transcript"
    let url = URL(fileURLWithPath: folder, isDirectory: true)
    if FileManager.default.fileExists(atPath: url.appendingPathComponent("index.html").path) {
        let page = Page(folder: url)
        await page.run()
        page.window.close()
    } else {
        check("the conversation page is found", false, "no index.html in \(url.path); run from app/ or pass --page <folder>")
    }
    print(failures == 0 ? "all checks passed" : "\(failures) checks failed")
    exit(failures == 0 ? 0 : 1)
}
app.run()
