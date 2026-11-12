import ApplicationServices
import Foundation

// Thin, typed access to the accessibility API. Every call here is a message to another app and can fail or time out;
// a missing value is `nil`, never a crash.

enum AX {
    static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    /// Several attributes in one message; missing ones come back nil.
    static func values(_ element: AXUIElement, _ attributes: [String]) -> [AnyObject?] {
        var values: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
        guard error == .success, let array = values as? [AnyObject], array.count == attributes.count else {
            return Array(repeating: nil, count: attributes.count)
        }
        return array.map { item in
            if item is NSNull { return nil }
            if CFGetTypeID(item) == AXValueGetTypeID(), AXValueGetType(item as! AXValue) == .axError { return nil }
            return item
        }
    }

    static func string(_ value: AnyObject?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func point(_ value: AnyObject?) -> CGPoint? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    static func size(_ value: AnyObject?) -> CGSize? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    /// Where the element is on screen, in points from the top-left of the main display.
    static func frame(_ element: AXUIElement) -> CGRect? {
        let got = values(element, [kAXPositionAttribute, kAXSizeAttribute])
        guard let origin = point(got[0]), let size = size(got[1]) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    static func children(_ element: AXUIElement, _ attribute: String = kAXChildrenAttribute) -> [AXUIElement] {
        (value(element, attribute) as? [AXUIElement]) ?? []
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    static func settable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
    }

    @discardableResult
    static func set(_ element: AXUIElement, _ attribute: String, _ value: AnyObject) -> Bool {
        AXUIElementSetAttributeValue(element, attribute as CFString, value) == .success
    }

    /// Perform an action. A timeout counts as done: an app that opens a dialog in answer does not reply until the
    /// dialog closes, and by then the press has long happened.
    static func perform(_ element: AXUIElement, _ action: String) -> Bool {
        let error = AXUIElementPerformAction(element, action as CFString)
        return error == .success || error == .cannotComplete
    }

    static func hitTest(_ app: AXUIElement, _ point: CGPoint) -> AXUIElement? {
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &element) == .success else { return nil }
        return element
    }

    static func role(_ element: AXUIElement) -> String { (value(element, kAXRoleAttribute) as? String) ?? "" }
    static func parent(_ element: AXUIElement) -> AXUIElement? { self.element(element, kAXParentAttribute) }
}

/// A control as the agent is told about it.
struct Control {
    let element: AXUIElement
    let role: String
    let subrole: String?
    /// What kind of thing it is, in plain words: "button", "text field".
    let kind: String
    let label: String?
    let value: String?
    let frame: CGRect
    let enabled: Bool
    let focused: Bool
    let selected: Bool

    var isSecure: Bool { subrole == "AXSecureTextField" }
    var isText: Bool { role == "AXTextField" || role == "AXTextArea" || role == "AXComboBox" }

    /// "the “Send” button", for sentences.
    var phrase: String {
        if let label { return "the “\(label.clipped(60))” \(kind)" }
        return kind.first.map { "aeiou".contains($0) ? "an \(kind)" : "a \(kind)" } ?? kind
    }
}

extension String {
    func clipped(_ limit: Int) -> String {
        let flat = replacingOccurrences(of: "\n", with: " ")
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }
}

/// Reads the controls and the text of one window.
struct WindowReader {
    /// Roles the agent can act on, with their plain names.
    private static let kinds: [String: String] = [
        "AXButton": "button", "AXCheckBox": "checkbox", "AXRadioButton": "radio button", "AXPopUpButton": "pop-up menu",
        "AXMenuButton": "menu button", "AXTextField": "text field", "AXTextArea": "text area", "AXComboBox": "combo box",
        "AXSlider": "slider", "AXLink": "link", "AXRow": "row", "AXMenuItem": "menu item", "AXDisclosureTriangle": "disclosure arrow",
        "AXIncrementor": "stepper", "AXColorWell": "colour well", "AXSwitch": "switch", "AXToggle": "toggle", "AXTab": "tab",
    ]
    private static let attributes = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXPositionAttribute,
        kAXSizeAttribute, kAXEnabledAttribute, kAXFocusedAttribute, kAXSelectedAttribute, kAXPlaceholderValueAttribute, kAXHelpAttribute,
    ]

    let windowFrame: CGRect
    var controls: [Control] = []
    var text: [String] = []
    private(set) var truncated = false
    private var visited = 0
    private let deadline = Date().addingTimeInterval(2.5)
    private let maxControls = 160

    init(windowFrame: CGRect) {
        self.windowFrame = windowFrame
    }

    /// Walk the window. Returns the text found under `element`, which is how rows and unlabelled buttons get a name.
    @discardableResult
    mutating func read(_ element: AXUIElement, depth: Int = 0, parentRole: String = "") -> [String] {
        visited += 1
        if visited > 4000 || depth > 40 || Date() > deadline {
            truncated = true
            return []
        }
        let got = AX.values(element, Self.attributes)
        let role = (got[0] as? String) ?? ""
        let subrole = got[1] as? String
        let frame: CGRect? = AX.point(got[5]).flatMap { origin in AX.size(got[6]).map { CGRect(origin: origin, size: $0) } }
        let isMenuItem = role == "AXMenuItem"
        // Things scrolled out of view or in a closed menu are not on screen; skip them and what is inside them.
        if let frame, role != "AXWindow", role != "AXMenu" {
            let onScreen = frame.width > 1 && frame.height > 1 && (isMenuItem || frame.intersects(windowFrame))
            if !onScreen { return [] }
        }

        if role == "AXStaticText" {
            let value = AX.string(got[4]) ?? AX.string(got[2])
            if let value { text.append(value) }
            return value.map { [$0] } ?? []
        }

        // Lists and tables: only the rows in view, so a list of thousands costs no more than a screenful.
        var kids: [AXUIElement]
        if role == "AXOutline" || role == "AXTable" || role == "AXList" {
            kids = AX.children(element, kAXVisibleRowsAttribute)
            if kids.isEmpty { kids = AX.children(element, "AXVisibleChildren") }
            if kids.isEmpty { kids = AX.children(element) }
        } else {
            kids = AX.children(element)
        }

        let kind: String? = {
            // Minimizing or zooming a window only gets in an agent's way; closing one is sometimes the task.
            if subrole == "AXMinimizeButton" || subrole == "AXZoomButton" || subrole == "AXFullScreenButton" { return nil }
            if role == "AXRadioButton", parentRole == "AXTabGroup" { return "tab" }
            if subrole == "AXSecureTextField" { return "password field" }
            if subrole == "AXSearchField" { return "search field" }
            if subrole == "AXSwitch" { return "switch" }
            return Self.kinds[role]
        }()
        let index = controls.count
        let listed = kind != nil && frame != nil && controls.count < maxControls
        if kind != nil, frame != nil, !listed { truncated = true }
        // Hold the place now so a row comes before the buttons inside it.
        if listed, let kind, let frame {
            controls.append(Control(element: element, role: role, subrole: subrole, kind: kind, label: nil, value: nil, frame: frame, enabled: true, focused: false, selected: false))
        }

        var inner: [String] = []
        for kid in kids {
            inner += read(kid, depth: depth + 1, parentRole: role)
            if inner.count > 12 { inner = Array(inner.prefix(12)) }
        }

        if listed, let kind, let frame {
            let isText = role == "AXTextField" || role == "AXTextArea" || role == "AXComboBox"
            let innerLabel = inner.isEmpty ? nil : inner.joined(separator: " · ")
            let label = subrole == "AXCloseButton" ? "close window" : AX.string(got[2]) ?? AX.string(got[3]) ?? (isText ? AX.string(got[10]) : innerLabel) ?? AX.string(got[11])
            var value: String?
            if subrole == "AXSecureTextField" {
                value = nil // never read a password back
            } else if isText || role == "AXPopUpButton" || role == "AXSlider" || role == "AXIncrementor" {
                value = AX.string(got[4]) ?? (got[4] as? NSNumber).map { $0.stringValue }
            } else if role == "AXCheckBox" || role == "AXRadioButton" || role == "AXSwitch" || role == "AXToggle" {
                value = (got[4] as? NSNumber).map { $0.intValue == 0 ? "off" : "on" }
            }
            controls[index] = Control(
                element: element, role: role, subrole: subrole, kind: kind, label: label, value: value, frame: frame,
                enabled: (got[7] as? Bool) ?? true, focused: (got[8] as? Bool) ?? false, selected: (got[9] as? Bool) ?? false
            )
        }
        // A row with no name is a divider or a heading: nothing to act on, so it gives up its place.
        if listed, role == "AXRow", controls[index].label == nil { controls.remove(at: index) }
        // A control's own name stands for the text inside it.
        if let title = AX.string(got[2]), inner.isEmpty { return [title] }
        return inner
    }
}
