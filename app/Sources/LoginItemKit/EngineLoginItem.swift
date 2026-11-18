import Foundation

/// A per-user launchd agent that starts the engine at login and restarts it if it crashes, so schedules and long
/// runs keep going without the app open. The app handles reading and changing the item; these decisions need no plist.
package enum EngineLoginItem {
    /// How launchd is told to treat the engine. `Background` limited the engine and its commands to the lowest
    /// priority, with disk use held back and only the efficiency cores (#344). `Interactive` is the priority of an
    /// engine the app starts itself; agents' commands are started a step lower by the engine (priority.ts).
    package static let processType = "Interactive"

    /// What the installed login item runs, and for which data folder.
    package struct Item {
        package let arguments: [String]
        package let home: String?
        /// Its `ProcessType`, nil when it has none.
        package let processType: String?

        package init(arguments: [String], home: String?, processType: String? = nil) {
            self.arguments = arguments
            self.home = home
            self.processType = processType
        }

        /// A copy of pi² on a data folder of its own must leave another folder's login item alone.
        package func serves(home other: String) -> Bool {
            guard let home else { return false }
            return URL(fileURLWithPath: home).standardizedFileURL.path == URL(fileURLWithPath: other).standardizedFileURL.path
        }
    }

    /// The data folder pi² uses when `PI2_HOME` does not name another. Only a copy on this folder may install the
    /// login item when there is none, so its label stays the one item for the copy in real use.
    package static var defaultHome: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("pi2").path
    }

    /// A copy may change only an item that serves its own data folder, and install one only on the default folder.
    package static func mayChange(_ item: Item?, home: String, defaultHome: String = EngineLoginItem.defaultHome) -> Bool {
        (item ?? Item(arguments: [], home: defaultHome)).serves(home: home)
    }

    /// An update may leave the engine running from the right build but still started by an old launchd item.
    /// Only refresh an existing item that serves this folder; never turn the login item on here.
    package static func needsRefresh(_ item: Item?, node: String, main: String, home: String) -> Bool {
        guard let item, item.serves(home: home) else { return false }
        return item.arguments != [node, main] || item.processType != processType
    }

    /// What the switch in Settings shows for a copy on the data folder `home`.
    package enum Switch: Equatable {
        case on, off
        /// The copy may not change the item; the text says why.
        case unavailable(String)

        package var isUnavailable: Bool {
            if case .unavailable = self { return true }
            return false
        }
    }

    package static func switchState(_ item: Item?, home: String, defaultHome: String = EngineLoginItem.defaultHome) -> Switch {
        if mayChange(item, home: home, defaultHome: defaultHome) { return item == nil ? .off : .on }
        if Item(arguments: [], home: defaultHome).serves(home: home) {
            return .unavailable("The login item starts the engine for another data folder, so pi² leaves it alone.")
        }
        return .unavailable("This copy of pi² has a data folder of its own. The login item belongs to the pi² that uses the usual data folder, so it cannot be changed here.")
    }
}
