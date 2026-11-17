import AppKit
import SwiftUI

/// What pressing Return does in a field that sends a message.
public enum ReturnKeyAction: Equatable, Sendable {
    /// Send the message.
    case send
    /// Put a line break at the cursor, in place of any selection.
    case newLine
    /// Let the field have the key: an input method is composing (Return confirms its candidate), or Command is held,
    /// which is for keyboard shortcuts such as the message field's ⌘Return.
    case leave
    /// Swallow it. Return held down repeats, and one press must not send twice. Control-Return means nothing in a
    /// message field, and left to the field it would type a space.
    case nothing
}

public enum ReturnKey {
    /// The modifier keys the decision looks at. Caps Lock, Fn and the keypad flag (Enter on the keypad) make no difference.
    public static let considered: EventModifiers = [.shift, .option, .control, .command]

    /// Return sends, Shift-Return and Option-Return (or both) start a new line, as in most chat apps. While an input
    /// method is composing (choosing a Japanese or Chinese candidate) every Return belongs to it, so confirming a
    /// candidate never sends half a message.
    public static func action(modifiers: EventModifiers, composing: Bool, repeating: Bool) -> ReturnKeyAction {
        if composing { return .leave }
        let held = modifiers.intersection(considered)
        if held.isEmpty { return repeating ? .nothing : .send }
        if held.isSubset(of: [.shift, .option]) { return .newLine }
        if held.contains(.command) { return .leave }
        return .nothing
    }

    /// The keys that count as Return: Return itself, and Enter on a keypad, which types the character 3.
    public static let keys: Set<KeyEquivalent> = [.return, KeyEquivalent("\u{03}")]
}

extension View {
    /// Makes a text field send with Return and start a new line with Shift-Return or Option-Return, leaving Return
    /// to an input method while it composes. Use it in place of `onSubmit` on a field that sends a message, or on any
    /// other field of several lines that acts on Return (a memory note saves with it), and give the field
    /// `axis: .vertical` so a line break has somewhere to go.
    public func sendsOnReturn(_ send: @escaping () -> Void) -> some View {
        modifier(SendsOnReturn(send: send))
    }
}

struct SendsOnReturn: ViewModifier {
    let send: () -> Void
    /// A view in the field's window, to reach the field's editor through. A focused field's editor is its window's
    /// first responder, and a key press only reaches this modifier while the field is focused.
    @State private var anchor = Anchor()

    func body(content: Content) -> some View {
        content
            .background(AnchorView(anchor: anchor))
            .onKeyPress(keys: ReturnKey.keys, phases: [.down, .repeat]) { press in
                let editor = anchor.view?.window?.firstResponder as? NSTextView
                let action = ReturnKey.action(
                    modifiers: press.modifiers, composing: editor?.hasMarkedText() ?? false, repeating: press.phase == .repeat)
                switch action {
                case .send:
                    send()
                    return .handled
                case .newLine:
                    guard let editor else { return .ignored }
                    // The editor's own command for a line break in a field: it replaces the selection, can be undone,
                    // and tells the field its text changed, so the binding and the field's height follow.
                    editor.insertNewlineIgnoringFieldEditor(nil)
                    return .handled
                case .nothing:
                    return .handled
                case .leave:
                    return .ignored
                }
            }
    }
}

@MainActor
final class Anchor {
    weak var view: NSView?
}

struct AnchorView: NSViewRepresentable {
    let anchor: Anchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
    }
}
