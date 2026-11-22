import SwiftUI

/// Renaming a conversation and deleting one, asked as the Mac asks them (app/Sources/pi2/Pi2App.swift: the Rename alert
/// and the Delete confirmation), shared by the conversations' list and the Archive.
struct ConversationsEditing: ViewModifier {
    /// The conversation being renamed, and the title typed.
    @Binding var renaming: ConversationsRow?
    /// The conversation being asked about, before it is deleted.
    @Binding var deleting: ConversationsDeletion?
    let rename: (ConversationsRow, String) -> Void
    let delete: (ConversationsDeletion) -> Void
    @State private var newTitle = ""

    func body(content: Content) -> some View {
        content
            .alert(renaming?.chat == true ? "Rename chat" : "Rename conversation", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Title", text: $newTitle)
                Button("Rename") {
                    if let renaming { rename(renaming, newTitle) }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
            .onChange(of: renaming) { _, row in newTitle = row?.title ?? "" }
            .confirmationDialog(
                "Delete “\(deleting?.title ?? "")”?",
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let deleting { delete(deleting) }
                    deleting = nil
                }
                Button("Cancel", role: .cancel) { deleting = nil }
            } message: {
                Text(deleting?.message ?? "")
            }
    }
}

/// A conversation asked about before it is deleted: what the confirmation names and says.
struct ConversationsDeletion: Identifiable, Equatable {
    let id: Int
    let title: String
    let chat: Bool

    /// The Mac's words. A worktree pi² made for it is kept, as the Mac's "Delete, Keep Worktree" keeps it: the phone does
    /// not offer "Delete and Remove Worktree" yet, which needs the `branches` event's word on whether it is clean.
    var message: String {
        chat
            ? "pi² will not show this chat again or bring it back. Its text stays in pi²'s data on your Mac. To put it away but keep it, archive it instead."
            : "Any work it is doing is stopped, and pi² will not show it again or bring it back. Its text stays in pi²'s data on your Mac, and a worktree pi² made for it is kept. To put it away but keep it, archive it instead."
    }
}

extension View {
    func conversationsEditing(renaming: Binding<ConversationsRow?>, deleting: Binding<ConversationsDeletion?>,
                              rename: @escaping (ConversationsRow, String) -> Void, delete: @escaping (ConversationsDeletion) -> Void) -> some View {
        modifier(ConversationsEditing(renaming: renaming, deleting: deleting, rename: rename, delete: delete))
    }
}
