import CoreGraphics
import Foundation

/// Mouse and keyboard events delivered to one app, not to whatever is in front: the person's pointer does not move and
/// their own typing goes where they are working.
enum Input {
    private static let source = CGEventSource(stateID: .combinedSessionState)
    /// Undocumented but long-standing event fields: the window a mouse event is for. Events posted straight to an app
    /// skip the window server, which normally fills these in, and some apps drop a click that has no window.
    private static let windowFields = [CGEventField(rawValue: 91), CGEventField(rawValue: 92)].compactMap { $0 }

    static func click(pid: pid_t, at point: CGPoint, windowID: CGWindowID?, count: Int) {
        let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
        stamp(move, windowID)
        move?.postToPid(pid)
        for click in 1...max(1, min(count, 3)) {
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
                event?.setIntegerValueField(.mouseEventClickState, value: Int64(click))
                stamp(event, windowID)
                event?.postToPid(pid)
                usleep(18000)
            }
        }
    }

    private static func stamp(_ event: CGEvent?, _ windowID: CGWindowID?) {
        guard let event, let windowID else { return }
        for field in windowFields { event.setIntegerValueField(field, value: Int64(windowID)) }
    }

    static func scroll(pid: pid_t, at point: CGPoint, lines: Int) {
        let event = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 1, wheel1: Int32(-lines), wheel2: 0, wheel3: 0)
        event?.location = point
        event?.postToPid(pid)
    }

    /// Type text as key events carrying the characters themselves, so the keyboard layout does not matter.
    static func type(pid: pid_t, text: String) {
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            // Keep surrogate pairs together.
            var end = min(index + 16, units.count)
            if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
            let chunk = Array(units[index..<end])
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                event?.postToPid(pid)
            }
            usleep(9000)
            index = end
        }
    }

    struct Combo {
        let key: CGKeyCode
        let flags: CGEventFlags
        /// As a person would write it: "⇧⌘Z".
        let display: String
    }

    private static let named: [String: (CGKeyCode, String)] = [
        "return": (36, "Return"), "enter": (36, "Return"), "tab": (48, "Tab"), "space": (49, "Space"), "delete": (51, "Delete"),
        "backspace": (51, "Delete"), "escape": (53, "Esc"), "esc": (53, "Esc"), "forwarddelete": (117, "Forward Delete"),
        "left": (123, "←"), "right": (124, "→"), "down": (125, "↓"), "up": (126, "↑"), "home": (115, "Home"), "end": (119, "End"),
        "pageup": (116, "Page Up"), "pagedown": (121, "Page Down"),
        "f1": (122, "F1"), "f2": (120, "F2"), "f3": (99, "F3"), "f4": (118, "F4"), "f5": (96, "F5"), "f6": (97, "F6"),
        "f7": (98, "F7"), "f8": (100, "F8"), "f9": (101, "F9"), "f10": (109, "F10"), "f11": (103, "F11"), "f12": (111, "F12"),
    ]
    /// Key positions on a US layout. A shortcut is a key position plus modifiers, so this is the right table for them.
    private static let characters: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "`": 50,
    ]

    /// "shift+cmd+z" → the key and its modifiers; nil when it names no key.
    static func parse(_ text: String) -> Combo? {
        var flags: CGEventFlags = []
        var symbols = ""
        var key: (CGKeyCode, String)?
        let parts = text.lowercased().replacingOccurrences(of: " ", with: "").split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        for (index, part) in parts.enumerated() {
            switch part {
            case "cmd", "command", "⌘": flags.insert(.maskCommand)
            case "shift", "⇧": flags.insert(.maskShift)
            case "opt", "option", "alt", "⌥": flags.insert(.maskAlternate)
            case "ctrl", "control", "⌃": flags.insert(.maskControl)
            case "fn": flags.insert(.maskSecondaryFn)
            case "":
                // "cmd++" means the plus key, which shares a key with "=".
                if index == parts.count - 1, index > 0 { key = (24, "+") } else { return nil }
            default:
                if let named = named[part] {
                    key = named
                } else if part.count == 1, let code = characters[part.first!] {
                    key = (code, part.uppercased())
                } else {
                    return nil
                }
            }
        }
        guard let key else { return nil }
        if flags.contains(.maskControl) { symbols += "⌃" }
        if flags.contains(.maskAlternate) { symbols += "⌥" }
        if flags.contains(.maskShift) { symbols += "⇧" }
        if flags.contains(.maskCommand) { symbols += "⌘" }
        return Combo(key: key.0, flags: flags, display: symbols + key.1)
    }

    static func press(pid: pid_t, _ combo: Combo) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: combo.key, keyDown: down)
            event?.flags = combo.flags
            event?.postToPid(pid)
            usleep(12000)
        }
    }
}
