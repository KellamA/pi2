// A developer's way to try ComputerKit from the command line, against one named app.
//
//   pi2-probe --only <bundle id> [--out <folder>] '<JSON array of requests>'
//
// Each request is what the engine would send: {"action":"screenshot"}, {"action":"click","element":3}. `app` defaults
// to the one named by --only, and nothing else can be touched. Pictures are saved to --out as step-N.jpg.
// This is not part of the app and is not copied into it.

import ComputerKit
import Foundation

var arguments = Array(CommandLine.arguments.dropFirst())
func take(_ flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...index + 1)
    return value
}
guard let only = take("--only"), let json = { take("--out") }() as String? ?? Optional(""), let script = arguments.last,
      let steps = try? JSONSerialization.jsonObject(with: Data(script.utf8)) as? [[String: Any]] else {
    FileHandle.standardError.write(Data("usage: pi2-probe --only <bundle id> [--out <folder>] '<JSON array of requests>'\n".utf8))
    exit(2)
}
let out = json.isEmpty ? nil : URL(fileURLWithPath: json, isDirectory: true)
if let out { try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true) }
print("accessibility: \(ComputerController.accessibilityGranted)  screen recording: \(ComputerController.screenRecordingGranted)")

let controller = ComputerController(ownBundleID: nil)
for (index, step) in steps.enumerated() {
    if let wait = step["wait"] as? Double {
        try? await Task.sleep(for: .milliseconds(Int(wait * 1000)))
        continue
    }
    let app = (step["app"] as? String) ?? only
    guard app == only else {
        print("--- step \(index + 1): refused, this probe only touches \(only)")
        continue
    }
    let request = ComputerRequest(
        action: (step["action"] as? String) ?? "", of: step["of"] as? String, app: app, apps: [only], element: step["element"] as? Int,
        x: (step["x"] as? NSNumber)?.doubleValue, y: (step["y"] as? NSNumber)?.doubleValue, text: step["text"] as? String, dy: step["dy"] as? Int,
        count: step["count"] as? Int, path: step["path"] as? String, image: (step["image"] as? Bool) ?? true, conversationId: 1
    )
    let started = Date()
    let reply = await controller.perform(request)
    print("--- step \(index + 1): \(request.action) → \(reply.ok ? "ok" : "FAILED") in \(Int(Date().timeIntervalSince(started) * 1000)) ms\(reply.summary.map { " [\($0)]" } ?? "")")
    print(reply.text)
    if let jpeg = reply.jpeg, let out {
        let file = out.appendingPathComponent("step-\(index + 1).jpg")
        try? jpeg.write(to: file)
        print("(picture: \(file.path), \(jpeg.count / 1024) KB)")
    }
}
