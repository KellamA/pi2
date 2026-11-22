import PiModels

// MARK: - Which conversations are chats

extension ConversationSummary {
    public var isChat: Bool { chat == true }
    public var isPinned: Bool { pinned == true }
}

extension ArchivedConversation {
    public var isChat: Bool { chat == true }
}
