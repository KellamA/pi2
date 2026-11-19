import Darwin
import Foundation
import PeerKit

// The engine's helper for #504: whether the process at the other end of one connection to the engine's socket is the
// pi² app. The engine starts it with that connection as file descriptor 3 and the app's bundle as its one argument,
// and reads one line of JSON: {"app": true|false, "pid": …, "why": "…"}. It never reads from or writes to the
// connection. Copied into the app as Contents/MacOS/pi2-peer by build.sh, and signed with it.
let arguments = CommandLine.arguments
guard arguments.count == 2, arguments[1].hasPrefix("/") else {
    FileHandle.standardError.write(Data("usage: pi2-peer <app bundle>, with the connection to check as file descriptor 3\n".utf8))
    exit(2)
}
print(PeerCheck.json(PeerCheck.verdict(socket: 3, app: arguments[1])))
