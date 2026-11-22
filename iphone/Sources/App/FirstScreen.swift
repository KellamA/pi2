import CryptoKit
import SwiftUI

/// The screen a phone not yet paired with a Mac opens on (docs/design/iphone.md, "Pairing"; the drafts' figure 2):
/// what pi² for iPhone is, how to pair, and the build's version. Pairing itself comes with the rest of #680, so for
/// now the screen says so in a plain line rather than showing a button that does nothing.
struct FirstScreen: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 14) {
                        Mark()
                        Text("pi² on your iPhone")
                            .font(.title2.bold())
                            .accessibilityAddTraits(.isHeader)
                        Text("Your Mac does the work. This iPhone shows it, and answers for you when agents need you.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: 8) {
                        Text("Pair with a Mac")
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                        Text("This build cannot pair yet: scanning the code your Mac shows arrives in the next build. On your Mac it will be pi² › Settings › Devices › Pair an iPhone.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity)
                    .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityElement(children: .combine)

                    #if DEBUG
                    DebugSection()
                    #endif

                    Text(BuildInfo.line)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.vertical, 40)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// pi²'s mark, as the Mac app's icon draws it. Decoration: VoiceOver reads the title beside it.
private struct Mark: View {
    @ScaledMetric(relativeTo: .title) private var side: CGFloat = 64

    var body: some View {
        Text("π²")
            .font(.system(size: side * 0.47, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: side, height: side)
            .background(Color(red: 0.545, green: 0.576, blue: 1.0), in: RoundedRectangle(cornerRadius: side * 0.28))
            .accessibilityHidden(true)
    }
}

#if DEBUG
/// What only a debug build shows: where its keys will be made (docs/iphone.md section 10) and the check of 4.3 for
/// the owner's phone. None of it is compiled into a release build.
private struct DebugSection: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Debug build")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if !SecureEnclave.isAvailable {
                Text("No Secure Enclave here, as in the simulator: this build will make its keys in software.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            NavigationLink("Check Face ID signing") {
                FaceIDCheckScreen()
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Signs twenty times under one Face ID, on this phone, and keeps nothing.")
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.orange.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }
}
#endif

#Preview("First screen") {
    FirstScreen()
}
