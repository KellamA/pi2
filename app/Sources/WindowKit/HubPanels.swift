
import SwiftUI

/// How a project's hub was left (docs/projects.md, 10.1): both panels shown, the conversation with the orchestrator
/// folded, or the board folded. The raw values are the ones `PI2_HUB` and the app's preferences use.
public enum HubFold: String, CaseIterable, Sendable {
    case both
    case conversationFolded = "conversation-folded"
    case boardFolded = "board-folded"

    /// The least width that shows both panels side by side.
    public static let narrowWidth: CGFloat = 640
    /// The least width of each column of the hub: the conversation with the orchestrator, and each pane beside it with the
    /// divider before it (#657).
    public static let columnWidth: CGFloat = 320

    /// The least width that shows the conversation beside panes that need `boardMinimum` (`HubLayout.minimum`): the
    /// conversation's column, the divider, and the panes. For the board alone it is `narrowWidth`.
    public static func bothWidth(boardMinimum: CGFloat) -> CGFloat { columnWidth + 1 + boardMinimum }

    /// The conversation's width beside panes that need `boardMinimum`, `across` of them side by side, in a hub `width`
    /// wide: its least, and an equal part with each of those panes of whatever is over, so that every column is as wide.
    public static func conversationWidth(_ width: CGFloat, boardMinimum: CGFloat, across: Int) -> CGFloat {
        columnWidth + max(0, width - bothWidth(boardMinimum: boardMinimum)) / CGFloat(1 + max(across, 1))
    }

    /// The fold shown: this one, unless the hub is too narrow for both panels. Too narrow, one side takes the width: the
    /// board, or, when an agent's conversation takes the board's place, that conversation (#473).
    public func shown(narrow: Bool, agent: Bool = false) -> HubFold {
        guard self == .both, narrow else { return self }
        return agent ? .conversationFolded : .boardFolded
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
/// fold the person chose is kept, and comes back when the window is wide enough again. `agent` says that the board's
/// place holds an agent's conversation (#473), or panes (#657), which then take the width when the window is narrow.
/// With panes, `across` of them side by side and needing `boardMinimum` together, the conversation is one column like
/// each of them, and the hub is narrow below `HubFold.bothWidth(boardMinimum:)`.
public struct HubPanels<Conversation: View, Board: View, Strip: View>: View {
    private let fold: HubFold
    private let narrow: Binding<Bool>
    private let agent: Bool
    private let across: Int
    private let boardMinimum: CGFloat
    private let conversation: Conversation
    private let board: Board
    private let strip: Strip
    /// The hub's width, once laid out: only panes side by side need it, to give the conversation its column.
    @State private var width: CGFloat = 0

    public init(fold: HubFold, narrow: Binding<Bool>, agent: Bool = false, across: Int = 1, boardMinimum: CGFloat = HubFold.narrowWidth - HubFold.columnWidth - 1,
                @ViewBuilder conversation: () -> Conversation, @ViewBuilder board: () -> Board, @ViewBuilder strip: () -> Strip) {
        self.fold = fold
        self.narrow = narrow
        self.agent = agent
        self.across = across
        self.boardMinimum = boardMinimum
        self.conversation = conversation()
        self.board = board()
        self.strip = strip()
    }

    public var body: some View {
        let shown = fold.shown(narrow: narrow.wrappedValue, agent: agent)
        // One pane or the board beside the conversation share the width equally, as the hub always did.
        let columns = across > 1 && shown == .both && width > 0
        let bothWidth = HubFold.bothWidth(boardMinimum: boardMinimum)
        HStack(spacing: 0) {
            if shown != .conversationFolded {
                conversation
                    .frame(minWidth: 0, maxWidth: columns ? HubFold.conversationWidth(width, boardMinimum: boardMinimum, across: across) : .infinity, minHeight: 0, maxHeight: .infinity)
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
        .onGeometryChange(for: Bool.self) { $0.size.width < bothWidth } action: { narrow.wrappedValue = $0 }
        .onGeometryChange(for: CGFloat.self) { [measures = across > 1] in measures ? $0.size.width : 0 } action: { width = $0 }
    }
}
