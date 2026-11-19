import Foundation
import FileLinkKit

// Checks what a click on a file link in a conversation, and the link's menu, do with what is on disk (#451), in a
// temporary folder of its own. It decides; it shows nothing in Finder and opens nothing.

var failures = 0
@MainActor func check(_ condition: Bool, _ what: String) {
    if !condition {
        failures += 1
        print("FAIL: \(what)")
    }
}
@MainActor func equal<T: Equatable>(_ actual: T, _ expected: T, _ what: String) {
    check(actual == expected, "\(what): \(actual), expected \(expected)")
}

let home = "/Users/someone"

// MARK: Which path a target names

equal(FileLink.path(of: "/tmp/a.txt", folder: nil, home: home), "/tmp/a.txt", "an absolute path")
equal(FileLink.path(of: "~/Documents/r.pdf", folder: nil, home: home), "/Users/someone/Documents/r.pdf", "a path from the home folder")
equal(FileLink.path(of: "~", folder: nil, home: home), home, "the home folder")
equal(FileLink.path(of: "file:///tmp/a%20b.txt", folder: nil, home: home), "/tmp/a b.txt", "a file address, decoded")
equal(FileLink.path(of: "file://localhost/tmp/a.txt", folder: nil, home: home), "/tmp/a.txt", "a file address on localhost")
equal(FileLink.path(of: "file:///tmp/a.txt#page=2", folder: nil, home: home), "/tmp/a.txt", "a file address's fragment is no part of the name")
equal(FileLink.path(of: "docs/x.md", folder: "/work/repo", home: home), "/work/repo/docs/x.md", "a relative path in a conversation's folder")
equal(FileLink.path(of: "../x.md", folder: "/work/repo/", home: home), "/work/repo/../x.md", "made whole later, not here")
for refused in [
    "docs/x.md", "file://server/share/x", "file:////server/x", "file:relative", "smb://server/share", "afp://server/x",
    "https://example.com", "//server/x", "#top", "?q", "~other/x", "", "   ", "/tmp/a\u{0}b", "file:///tmp/a%00b",
    "/" + String(repeating: "a", count: 5000),
] {
    equal(FileLink.path(of: refused, folder: nil, home: home), nil, "refused: \(refused.prefix(40))")
}
equal(FileLink.path(of: "~other/x", folder: "/work", home: home), nil, "another person's home folder, even with a folder")

// MARK: Made whole, in a folder of our own

let fm = FileManager.default
let made = fm.temporaryDirectory.appendingPathComponent("pi2-file-link-check-\(getpid())")
try? fm.removeItem(at: made)
try! fm.createDirectory(at: made, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: made) }
// The temporary folder is reached through a link on macOS (/var is /private/var), which the whole path leaves out.
let root = made.path
// realpath(3), not resolvingSymlinksInPath, which gives /var back again.
let real = String(cString: realpath(root, nil)!)
check(real != root, "the temporary folder is reached through a link")

@MainActor func file(_ name: String, _ text: String = "x", executable: Bool = false) {
    let path = root + "/" + name
    try! fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    fm.createFile(atPath: path, contents: Data(text.utf8), attributes: executable ? [.posixPermissions: 0o755] : [.posixPermissions: 0o644])
}
file("report.pdf", "%PDF-1.4\n")
file("notes.md", "# Notes\n")
file("Some Folder/inside.txt")
file("run.sh", "#!/bin/sh\necho hi\n", executable: true)
file("script.py", "print(1)\n")
file("runme", "#!/bin/sh\necho hi\n", executable: true)
file("doc.txt", "words\n", executable: true)
file("go.command", "#!/bin/sh\n", executable: false)
file("disk.dmg", "x")
file("Tool.app/Contents/Info.plist", "<plist/>")
file("Tool.app/Contents/MacOS/Tool", "#!/bin/sh\n", executable: true)
file("Letter.rtfd/TXT.rtf", "{\\rtf1 hi}")
try! fm.createSymbolicLink(atPath: root + "/link.pdf", withDestinationPath: "report.pdf")
try! fm.createSymbolicLink(atPath: root + "/to-folder", withDestinationPath: root + "/Some Folder")
try! fm.createSymbolicLink(atPath: root + "/loop-a", withDestinationPath: "loop-b")
try! fm.createSymbolicLink(atPath: root + "/loop-b", withDestinationPath: "loop-a")

let none: Set<String> = []
equal(FileLink.resolve(root + "/report.pdf", far: none), .found(real + "/report.pdf", .file), "found: a file, its path made whole")
equal(FileLink.resolve(root + "/link.pdf", far: none), .found(real + "/report.pdf", .file), "a symbolic link is followed")
equal(FileLink.resolve(root + "/Some Folder/../notes.md", far: none), .found(real + "/notes.md", .file), "'..' is worked out")
equal(FileLink.resolve(root + "/to-folder/../notes.md", far: none), .found(real + "/notes.md", .file), "'..' after a link goes up from where the link leads")
equal(FileLink.resolve(root + "/Some Folder", far: none), .found(real + "/Some Folder", .folder), "a folder")
equal(FileLink.resolve(root + "/Some Folder/", far: none), .found(real + "/Some Folder", .folder), "a folder with a slash")
equal(FileLink.resolve(root + "/Tool.app", far: none), .found(real + "/Tool.app", .package), "an application is a package")
equal(FileLink.resolve(root + "/gone.pdf", far: none), .missing(root + "/gone.pdf"), "gone")
equal(FileLink.resolve(root + "/Some Folder/../gone.pdf", far: none), .missing(root + "/gone.pdf"), "gone, said tidily")
equal(FileLink.resolve(root + "/loop-a", far: none), .missing(root + "/loop-a"), "a loop of links leads nowhere")
equal(FileLink.resolve(root + "/report.pdf/x", far: none), .missing(root + "/report.pdf/x"), "nothing is inside a file")
equal(FileLink.resolve("relative.txt", far: none), .missing("relative.txt"), "a path that is not absolute")
// A volume pi² does not look into: stopped at, whether named directly or reached through a link.
let far: Set<String> = [real + "/Some Folder"]
equal(FileLink.resolve(real + "/Some Folder/inside.txt", far: far), .elsewhere(real + "/Some Folder/inside.txt"), "a far volume")
equal(FileLink.resolve(root + "/to-folder/inside.txt", far: far), .elsewhere(root + "/to-folder/inside.txt"), "a far volume through a link")
equal(FileLink.resolve(root + "/report.pdf", far: far), .found(real + "/report.pdf", .file), "beside a far volume")
// This Mac's own list: the automounter's folders are in it, and a path into one is never looked up.
let mounts = FileLink.farMounts()
check(!mounts.contains("/"), "the start-up volume is this Mac's own")
if mounts.contains("/System/Volumes/Data/home") {
    check(mounts.contains("/home"), "a far mount under its firm-linked name too")
    equal(FileLink.resolve("/home/someone/x.txt"), .elsewhere("/home/someone/x.txt"), "/home is automounted: not looked into")
    print("Checked that /home, automounted here, is not looked into.")
} else {
    print("No automounted /home on this Mac; that part was not checked.")
}

// MARK: Open, in the menu only

@MainActor func resolved(_ name: String) -> (String, FileLink.Kind) {
    guard case .found(let path, let kind) = FileLink.resolve(root + "/" + name, far: none) else { fatalError("\(name) is not there") }
    return (path, kind)
}
for (name, allowed) in [
    ("report.pdf", true), ("notes.md", true), ("doc.txt", true), ("Letter.rtfd", true),
    ("Some Folder", false), ("Tool.app", false), ("run.sh", false), ("script.py", false), ("runme", false),
    ("go.command", false), ("disk.dmg", false), ("Tool.app/Contents/MacOS/Tool", false),
] {
    let (path, kind) = resolved(name)
    equal(FileLink.mayOpen(path, kind: kind), allowed, "Open for \(name)")
}

// MARK: A click, and the menu

equal(FileLink.show(FileLink.resolve(root + "/report.pdf", far: none), home: home), .reveal(real + "/report.pdf"), "a click shows a file in its folder")
equal(FileLink.show(FileLink.resolve(root + "/Tool.app", far: none), home: home), .reveal(real + "/Tool.app"), "and an application, never running it")
equal(FileLink.show(FileLink.resolve(root + "/Some Folder", far: none), home: home), .openFolder(real + "/Some Folder"), "a folder opens in Finder")
equal(FileLink.show(.missing(home + "/Documents/gone.pdf"), home: home),
      .notice("There is no file or folder at ~/Documents/gone.pdf. It may have been moved or deleted."), "gone: a notice")
equal(FileLink.show(.elsewhere("/Volumes/share/x.pdf"), home: home),
      .notice("/Volumes/share/x.pdf is on a network volume, and pi² shows only files on this Mac."), "elsewhere: a notice")

let link = { (name: String) in FileLink.menu(FileLink.resolve(root + "/" + name, far: none), code: false).map(\.rawValue) }
let code = { (name: String) in FileLink.menu(FileLink.resolve(root + "/" + name, far: none), code: true).map(\.rawValue) }
equal(link("report.pdf"), ["Show in Finder", "Open", "Copy Path"], "the menu for a document")
equal(link("Tool.app"), ["Show in Finder", "Copy Path"], "the menu for an application")
equal(link("run.sh"), ["Show in Finder", "Copy Path"], "the menu for a script")
equal(link("Some Folder"), ["Show in Finder", "Copy Path"], "the menu for a folder")
equal(link("gone.pdf"), ["Show in Finder", "Copy Path"], "a link to nothing keeps its items, and Show says it is gone")
equal(code("notes.md"), ["Show in Finder", "Open", "Copy Path"], "a path written as code, when something is there")
equal(code("gone.pdf"), [], "a path written as code, when nothing is: no items")
equal(FileLink.abbreviated(home, home: home), "~", "the home folder itself")
equal(FileLink.abbreviated("/Users/someoneelse/x", home: home), "/Users/someoneelse/x", "another folder that starts the same")

if failures > 0 {
    print("\(failures) file link check(s) failed.")
    exit(1)
}
print("File link checks passed.")
