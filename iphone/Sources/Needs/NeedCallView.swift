import SwiftUI

/// An approval's whole call in its box: every argument in full, wrapped, never cut. In a card the box keeps to a height
/// and scrolls inside it; when there is more than it shows, `showAll` offers the card on a screen of its own, where the
/// box grows to the whole call. A key the engine hid reads as hidden, not as the command's own text.
struct NeedCallView: View {
    let call: NeedCall
    /// Whether the box keeps to a height (in a card), or shows everything (the card opened on its own).
    var limited = true
    /// Called by the box's "Show all of it" when the call is taller than the box.
    var showAll: (() -> Void)? = nil

    @ScaledMetric(relativeTo: .footnote) private var maxHeight: CGFloat = 200
    @State private var contentHeight: CGFloat = 0

    private var overflows: Bool { limited && contentHeight > maxHeight + 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if limited {
                ScrollView {
                    content
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: contentHeight == 0 ? maxHeight : min(contentHeight, maxHeight))
                .scrollIndicatorsFlash(trigger: overflows)
            } else {
                content
            }
            if overflows, let showAll {
                Button(action: showAll) {
                    Label("Show all of it", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.footnote.weight(.medium))
                }
                .buttonStyle(.borderless)
                .accessibilityHint("Opens the card on a screen of its own, with the whole call")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            if call.parts.isEmpty {
                Text("No arguments")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(call.parts) { part in
                VStack(alignment: .leading, spacing: 2) {
                    if let label = part.label {
                        Text(label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    NeedHiddenText(text: part.text, code: part.code)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(part.label.map { "\($0): \(NeedHiddenCall.spoken(part.text))" } ?? NeedHiddenCall.spoken(part.text))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
        .textSelection(.enabled)
    }
}

/// A text with the keys the engine hid drawn as such: a marked word in its own type, never as the call's own text.
struct NeedHiddenText: View {
    let text: String
    var code = false

    var body: some View {
        Text(attributed)
            .font(code ? .footnote.monospaced() : .callout)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        for piece in NeedHiddenCall.pieces(of: text) {
            switch piece {
            case .text(let words):
                result.append(AttributedString(words))
            case .hidden:
                // Not the placeholder's own brackets, which a command could hold: a word set apart, in a type the call is
                // never shown in, on a marked ground.
                var hidden = AttributedString("\u{202F}key\u{00A0}hidden\u{202F}")
                hidden.font = .footnote.italic().weight(.semibold)
                hidden.foregroundColor = Color(.label)
                hidden.backgroundColor = Color(.systemOrange).opacity(0.35)
                result.append(hidden)
            }
        }
        return result
    }
}

#Preview("A call with a hidden key") {
    NeedCallView(call: NeedCall(tool: "bash", arguments: .object([
        "command": .string("curl -H 'Authorization: Bearer [key hidden]' https://api.example.com/v1/things | jq ."),
        "timeout": .number(120),
    ])))
    .padding()
}
