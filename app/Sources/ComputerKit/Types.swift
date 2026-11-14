import Foundation

/// One thing an agent asks to do on screen, as the engine sends it.
public struct ComputerRequest: Sendable {
    public var action: String
    /// For "describe": the action to put into words. Describing changes nothing.
    public var of: String?
    public var app: String?
    /// For "list_apps": the apps the agent may use.
    public var apps: [String]
    public var element: Int?
    public var x: Double?
    public var y: Double?
    public var text: String?
    public var dy: Int?
    public var count: Int?
    public var path: String?
    /// Whether a picture is wanted; false for a model that cannot see images.
    public var image: Bool
    /// Whose view of the window this is: control numbers belong to one conversation's latest look at one app.
    public var conversationId: Int

    public init(
        action: String, of: String? = nil, app: String? = nil, apps: [String] = [], element: Int? = nil, x: Double? = nil, y: Double? = nil,
        text: String? = nil, dy: Int? = nil, count: Int? = nil, path: String? = nil, image: Bool = true, conversationId: Int = 0
    ) {
        self.action = action
        self.of = of
        self.app = app
        self.apps = apps
        self.element = element
        self.x = x
        self.y = y
        self.text = text
        self.dy = dy
        self.count = count
        self.path = path
        self.image = image
        self.conversationId = conversationId
    }
}

/// The answer: text for the model, a short line for the person, and a picture of the window when one was taken.
public struct ComputerReply: Sendable, Error {
    public var ok: Bool
    public var text: String
    public var summary: String?
    public var jpeg: Data?

    public init(ok: Bool, text: String, summary: String? = nil, jpeg: Data? = nil) {
        self.ok = ok
        self.text = text
        self.summary = summary
        self.jpeg = jpeg
    }

    static func failure(_ text: String) -> ComputerReply { ComputerReply(ok: false, text: text) }
}

/// The rules that hold whatever the engine says, so a confused or compromised engine still cannot reach these apps.
public enum ComputerPolicy {
    /// Shells and script runners (typing there is running code), password managers.
    static let never = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty", "net.kovidgoyal.kitty",
        "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper", "com.apple.ScriptEditor2", "com.apple.Automator",
        "com.apple.keychainaccess", "com.apple.Passwords", "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
    ]
    /// Browsers hold every signed-in account, and System Settings changes the Mac: these can be looked at only. So can copies of pi²; see `pi2`.
    static let viewOnly = [
        "com.apple.systempreferences", "com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", "com.microsoft.edgemac",
        "company.thebrowser.Browser", "company.thebrowser.dia", "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
    ]

    /// pi² itself, where an agent could approve its own requests: never usable. A copy under another bundle id that starts
    /// with this one, such as a throwaway test build, is look-only, so an agent working on pi² can check a change by looking.
    static let pi2 = "dev.pi2.app"

    private static func matches(_ list: [String], _ bundleID: String) -> Bool {
        list.contains { bundleID == $0 || bundleID.hasPrefix($0 + ".") }
    }

    public static func isNever(_ bundleID: String) -> Bool { bundleID == pi2 || matches(never, bundleID) }
    public static func isViewOnly(_ bundleID: String) -> Bool { bundleID.hasPrefix(pi2 + ".") || matches(viewOnly, bundleID) }
}
