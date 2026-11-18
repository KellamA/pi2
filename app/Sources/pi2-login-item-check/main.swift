import LoginItemKit

// Only the decision code is linked here: no plist or launchd calls.
let home = "/data/pi2"
let copyHome = "/data/pi2-test"
let node = "/Applications/pi2.app/Contents/Resources/node"
let main = "/Applications/pi2.app/Contents/Resources/engine/src/main.ts"
let arguments = [node, main]
let current = EngineLoginItem.Item(arguments: arguments, home: home, processType: EngineLoginItem.processType)
let unreadable = EngineLoginItem.Item(arguments: [], home: nil)

precondition(EngineLoginItem.mayChange(nil, home: home, defaultHome: home), "The usual copy can install the item.")
precondition(!EngineLoginItem.mayChange(nil, home: copyHome, defaultHome: home), "A test copy cannot install the item.")
precondition(EngineLoginItem.switchState(nil, home: home, defaultHome: home) == .off)
precondition(EngineLoginItem.switchState(nil, home: copyHome, defaultHome: home).isUnavailable)
precondition(EngineLoginItem.switchState(current, home: home, defaultHome: home) == .on)
precondition(EngineLoginItem.switchState(current, home: copyHome, defaultHome: home).isUnavailable)
precondition(EngineLoginItem.switchState(unreadable, home: home, defaultHome: home).isUnavailable)

func needsRefresh(_ item: EngineLoginItem.Item?, for folder: String = home) -> Bool {
    EngineLoginItem.needsRefresh(item, node: node, main: main, home: folder)
}

// The engine can already be from this build, with the very same paths, after an update in place.
let background = EngineLoginItem.Item(arguments: arguments, home: home, processType: "Background")
let unspecified = EngineLoginItem.Item(arguments: arguments, home: home)
precondition(needsRefresh(background), "Same paths with Background still need a refresh.")
precondition(needsRefresh(unspecified), "Same paths with no ProcessType still need a refresh.")
precondition(!needsRefresh(current), "The current item must not cause a restart.")

let oldNode = EngineLoginItem.Item(arguments: ["/old/node", main], home: home, processType: EngineLoginItem.processType)
let oldMain = EngineLoginItem.Item(arguments: [node, "/old/main.ts"], home: home, processType: EngineLoginItem.processType)
precondition(needsRefresh(oldNode), "A changed Node path needs a refresh.")
precondition(needsRefresh(oldMain), "A changed engine path needs a refresh.")
precondition(needsRefresh(background, for: home + "/../pi2"), "Equivalent data folder paths match.")
precondition(!needsRefresh(background, for: copyHome), "Do not refresh another copy's item.")
precondition(!needsRefresh(unreadable), "Do not refresh an item whose data folder is unknown.")
precondition(!needsRefresh(nil), "Do not turn on the login item automatically.")

print("Login item checks passed.")
