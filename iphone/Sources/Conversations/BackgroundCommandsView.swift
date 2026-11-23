import SwiftUI

/// The background commands: a list, one's output read on a screen of its own, and Stop (docs/design/iphone.md, "Every
/// screen and function of the Mac app"). #698 builds it: replace this body, keep the type and its initialiser, and add
/// files beside it in `Conversations/`. A command's output opens with `openRoute(.backgroundCommands(output: id))`.
struct BackgroundCommandsView: View {
    /// The command whose output it shows, as `BackgroundCommand.id`; nil for the list.
    let commandID: String?

    init(commandID: String? = nil) {
        self.commandID = commandID
    }

    var body: some View {
        FeaturePlaceholder(screen: commandID == nil ? "Background commands" : "A command's output", issue: 698,
                           details: commandID.map { ["command \($0)"] } ?? [])
    }
}
