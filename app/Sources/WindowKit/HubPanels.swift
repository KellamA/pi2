
import SwiftUI

/// How a project's hub was left (docs/projects.md, 10.1): both panels shown, the conversation with the orchestrator
/// folded, or the board folded. The raw values are the ones `PI2_HUB` and the app's preferences use.
public enum HubFold: String, CaseIterable, Sendable {
    case both
    case conversationFolded = "conversation-folded"
    case boardFolded = "board-folded"

    /// The least width that shows both panels side by side.
    public static let narrowWidth: CGFloat = 640

    /// The fold shown: this one, unless the hub is too narrow for both panels.
    public func shown(narrow: Bool) -> HubFold {
        self == .both && narrow ? .boardFolded : self
    }
}

/// A project's hub below its bar: the conversation with the orchestrator on the left and the board on the right, or one
/// of them across the width (#471). With the conversation folded, `strip` runs along the bottom of the board: the
/// orchestrator's last words and a field to answer it.
///
/// Its own module, with stand-ins for the panels, so that pi2-window-check can show it at the window's smallest size in
/// each fold. Nothing here asks the panels how big they would like to be: each panel takes the room it is given and no
/// more (`minWidth: 0`), so what they show never decides the window's size, and the hub needs `narrowWidth` to show both
/// side by side (`HubFold.narrowWidth`). Narrower than that, the board folds by itself, and `narrow` is told so that the hub can say it; the
/// fold the person chose is kept, and comes back when the window is wide enough again.
public struct HubPanels<Conversation: View, Board: View, Strip: View>: View {
    private let fold: HubFold
    private let narrow: Binding<Bool>
    private let conversation: Conversation
    private let board: Board
    private let strip: Strip

    public init(fold: HubFold, narrow: Binding<Bool>, @ViewBuilder conversation: () -> Conversation, @ViewBuilder board: () -> Board, @ViewBuilder strip: () -> Strip) {
        self.fold = fold
        self.narrow = narrow
        self.conversation = conversation()
        self.board = board()
        self.strip = strip()
    }

    public var body: some View {
        let shown = fold.shown(narrow: narrow.wrappedValue)
        HStack(spacing: 0) {
            if shown != .conversationFolded {
                conversation
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .clipped()
            }
            if shown == .both {
                Rectangle().fill(.separator).frame(width: 1)
            }
            if shown != .boardFolded {
                VStack(spacing: 0) {
                    board
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
                        .clipped()
                    if shown == .conversationFolded { strip }
                }
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        // The width the hub is given, never what its panels would like: it changes only as the window or the sidebar does.
        .onGeometryChange(for: Bool.self) { $0.size.width < HubFold.narrowWidth } action: { narrow.wrappedValue = $0 }
    }
}
