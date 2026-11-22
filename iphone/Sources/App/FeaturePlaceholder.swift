import SwiftUI

/// What a feature's entry view shows until its issue builds it: which screen this is, what it was opened with, and the
/// issue that builds it. It says plainly that the screen is not built, rather than pretending to be it. The feature's
/// worker replaces the body of the entry view and stops using it.
struct FeaturePlaceholder: View {
    let screen: String
    let issue: Int
    var details: [String] = []

    @Environment(\.placement) private var placement

    var body: some View {
        let content = VStack(spacing: 10) {
            Text(screen)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            ForEach(details, id: \.self) { line in
                Text(line)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)
            }
            Text("Not built yet: #\(issue) builds this screen.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(20)
        .frame(maxWidth: .infinity)
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        .padding(16)

        if placement == .screen {
            content
                .frame(maxHeight: .infinity)
                .navigationTitle(screen)
                .navigationBarTitleDisplayMode(.inline)
        } else {
            content
        }
    }
}
