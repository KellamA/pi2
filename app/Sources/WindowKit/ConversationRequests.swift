import SwiftUI

/// The space above the composer is shared by the transcript and the requests. Leave at least two fifths of it
/// for the transcript when requests pile up, without stretching a short stack to fill its allowance.
public struct ConversationRequests<Item: Identifiable, Card: View>: View {
    private let items: [Item]
    private let availableHeight: CGFloat
    private let card: (Item) -> Card
    @State private var contentHeight: CGFloat = 0
    @State private var visible: [Item.ID] = []

    public init(_ items: [Item], availableHeight: CGFloat, @ViewBuilder card: @escaping (Item) -> Card) {
        self.items = items
        self.availableHeight = availableHeight
        self.card = card
    }

    public var body: some View {
        let limit = items.count > 1 ? (availableHeight * 0.6).rounded(.down) : contentHeight
        let overflowing = contentHeight > limit
        let captionHeight = min(22, limit)
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(items, content: card)
                }
                .scrollTargetLayout()
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, height in
                contentHeight = height
            }
            .onScrollTargetVisibilityChange(idType: Item.ID.self, threshold: 0.99) { visible = $0 }
            .frame(maxWidth: .infinity)
            .frame(height: overflowing ? limit - captionHeight : contentHeight)
            if overflowing {
                let hidden = items.count - items.count { visible.contains($0.id) }
                Text(hidden == 1 ? "1 more request · Scroll to see all" : "\(hidden) more requests · Scroll to see all")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .frame(height: captionHeight)
                    .clipped()
            }
        }
    }
}
