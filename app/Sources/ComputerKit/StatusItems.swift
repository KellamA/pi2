import ApplicationServices

package enum StatusItems {
    package static func label(title: String?, description: String?, help: String?) -> String? {
        // SwiftUI's MenuBarExtra can put the count in the accessibility description rather than the title.
        AX.string(description as NSString?) ?? AX.string(title as NSString?) ?? AX.string(help as NSString?)
    }

    package static func action(in actions: [String]) -> String {
        actions.contains(kAXShowMenuAction) && !actions.contains(kAXPressAction) ? kAXShowMenuAction : kAXPressAction
    }

    static func read(of app: AXUIElement, pid: pid_t) -> [Control] {
        guard let bar = AX.element(app, kAXExtrasMenuBarAttribute) else { return [] }
        return AX.children(bar).prefix(40).compactMap { item in
            var owner: pid_t = 0
            guard AXUIElementGetPid(item, &owner) == .success, owner == pid else { return nil }
            let got = AX.values(item, [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXEnabledAttribute])
            return Control(element: item, role: (got[0] as? String) ?? "", subrole: nil, kind: "menu bar item",
                           label: label(title: got[1] as? String, description: got[2] as? String, help: got[3] as? String), value: nil,
                           frame: .zero, enabled: (got[4] as? Bool) ?? true, focused: false, selected: false, statusItem: true)
        }
    }
}
