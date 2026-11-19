
import ApplicationServices
import SwiftUI

/// An element of a window, as much of it as deciding how to work it needs. `AXUIElement`, an element of another app,
/// is one; `pi2-computer-check` has another that reads a window of its own in-process, as the accessibility server
/// answers for it, so the decisions below can be checked against what SwiftUI really reports without Accessibility.
public protocol AccessibleElement {
    var accessibleRole: String { get }
    /// The actions it answers to, such as `AXPress` and `AXShowMenu`.
    var accessibleActions: [String] { get }
    var accessibleChildren: [Self] { get }
    var accessibleParent: Self? { get }
}

/// How the computer tool reaches what an agent asks for, decided from what the elements say they answer to.
public enum Reaching {
    public static let press = "AXPress"
    public static let showMenu = "AXShowMenu"

    /// Whether a click on `element` can be an accessibility press, which works with the app in the background. A
    /// SwiftUI disclosure group in a grouped Form answers to nothing (#367) unless its label is `pressableDisclosure`.
    public static func pressable<E: AccessibleElement>(_ element: E) -> Bool {
        element.accessibleActions.contains(press)
    }

    /// The element whose context menu is the one a person gets by right-clicking `element`: itself, if it answers to
    /// `AXShowMenu`; else the nearest thing inside it that does, which is where SwiftUI puts a list row's `.contextMenu`
    /// (on the row's text, inside the row and its cell); else a few levels around it, short of the window. Nil when
    /// nothing near answers, and only a secondary click can try.
    public static func menuTarget<E: AccessibleElement>(of element: E) -> E? {
        if element.accessibleActions.contains(showMenu) { return element }
        var queue = element.accessibleChildren.map { ($0, 1) }
        var visited = 0
        while !queue.isEmpty, visited < 80 {
            let (candidate, depth) = queue.removeFirst()
            visited += 1
            if candidate.accessibleActions.contains(showMenu) { return candidate }
            if depth < 4 { queue += candidate.accessibleChildren.map { ($0, depth + 1) } }
        }
        var outer = element.accessibleParent
        for _ in 0..<3 {
            guard let candidate = outer, !["AXWindow", "AXApplication", "AXScrollArea"].contains(candidate.accessibleRole) else { break }
            if candidate.accessibleActions.contains(showMenu) { return candidate }
            outer = candidate.accessibleParent
        }
        return nil
    }
}

/// An element of another app's window, through the accessibility API.
struct AXNode: AccessibleElement {
    let element: AXUIElement
    init(_ element: AXUIElement) { self.element = element }
    var accessibleRole: String { AX.role(element) }
    var accessibleActions: [String] { AX.actions(element) }
    var accessibleChildren: [AXNode] { AX.children(element).map(AXNode.init) }
    var accessibleParent: AXNode? { AX.parent(element).map(AXNode.init) }
}

extension View {
    /// Put on a `DisclosureGroup`'s label, so the group opens and closes through accessibility: for the computer tool,
    /// which works a window in the background by accessibility alone, and for VoiceOver. In a grouped `Form` SwiftUI's
    /// own disclosure arrow answers to no action at all, and a click is all that opens it (#367). With this, the arrow
    /// answers `AXPress`, named after the label, and a press toggles it once, in a Form or anywhere else.
    /// `pi2-computer-check` checks both.
    public func pressableDisclosure(_ isExpanded: Binding<Bool>) -> some View {
        accessibilityElement(children: .combine)
            .accessibilityAction { isExpanded.wrappedValue.toggle() }
    }
}
