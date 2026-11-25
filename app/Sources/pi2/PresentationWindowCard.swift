import AppKit
import PiModels
import SwiftUI

/// The pictures of a `present` question on its card under Needs you (docs/design/presenting.md, "Picking"): each item of
/// the version asked about, small, from `presented.picture` (a page by its snapshot once drawn), with its label; a click
/// opens the presentation's window at that item. The card's buttons and field are the decision's own.
///
/// Which presentation a decision is about is found from the conversation's records: the version whose question's `need`
/// is this need's id (an Inbox item's for one that waits, the stored need's for `wait: false`). A decision that is no
/// presentation's (`needs_you`'s) finds none and shows nothing here.
struct NeedPresentationPictures<Question: View>: View {
    let engine: EngineClient
    let need: NeedItem
    /// The card's question, above the pictures: the view that is always there, which reads the records.
    @ViewBuilder let question: Question
    @State private var found: Found?

    struct Found: Equatable {
        let ref: PresentationRef
        let version: PresentedVersion
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            question
            if let found {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(found.version.items.enumerated()), id: \.offset) { index, item in
                            NeedPresentationThumb(engine: engine, ref: found.ref, version: found.version.version, index: index, item: item)
                        }
                    }
                }
                .frame(height: 92)
            }
        }
        // Read again when the needs change (a page drawn since, another version asked about) as well as at first.
        .task(id: "\(need.id)-\(engine.needs.count)") { await find() }
    }

    private func find() async {
        guard need.kind == "decision", let records = try? await engine.presentedList(conversation: need.conversationId) else { return }
        for record in records {
            if let version = record.versions.last(where: { $0.question?.need == need.id }) {
                let next = Found(ref: PresentationRef(conversation: need.conversationId, presentation: record.id), version: version)
                if next != found { found = next }
                return
            }
        }
    }
}

private struct NeedPresentationThumb: View {
    let engine: EngineClient
    let ref: PresentationRef
    let version: Int
    let index: Int
    let item: PresentedItem
    @State private var image: NSImage?

    var body: some View {
        Button {
            PresentationWindows.shared.show(ref, version: version, item: index)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                ZStack {
                    Theme.card
                    if let image {
                        Image(nsImage: image).resizable().interpolation(.medium).aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: item.kind == .page ? "doc.richtext" : "photo").foregroundStyle(Theme.tx3)
                    }
                }
                .frame(width: 112, height: 70)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.line2, lineWidth: 1))
                Text(verbatim: label).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.tx2).lineLimit(1)
                    .frame(width: 112, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open it in its window")
        .task(id: "\(ref.presentation)-\(version)-\(index)-\(item.snapshot?.isDrawn == true)") { await load() }
    }

    private var label: String {
        let label = PresentationText.plain(item.label, limit: PresentationText.label)
        if item.kind == .page { return label.isEmpty || label == "Page" ? "Page" : "\(label) · Page" }
        return label.isEmpty ? "Picture \(index + 1)" : label
    }

    private func load() async {
        guard image == nil, let conversation = ref.conversation else { return }
        if item.kind == .page, item.snapshot?.isDrawn != true { return }
        guard let bytes = try? await engine.presentedPicture(conversation: conversation, presentation: ref.presentation, version: version, item: index),
              let picture = PresentedPicture.image(bytes.data, mimeType: bytes.mimeType) else { return }
        image = Self.small(picture)
    }

    /// A copy no larger than the thumbnail needs, so a card under Needs you does not keep a large picture for itself.
    private static func small(_ picture: NSImage) -> NSImage {
        let side: CGFloat = 240
        let size = picture.size
        guard size.width > side || size.height > side, size.width > 0, size.height > 0 else { return picture }
        let scale = min(side / size.width, side / size.height)
        let target = NSSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        // Drawn once into pixels of its own at twice the size, for a Retina screen; the picture itself is let go.
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(target.width * 2), pixelsHigh: Int(target.height * 2), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return picture }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        picture.draw(in: NSRect(x: 0, y: 0, width: target.width * 2, height: target.height * 2))
        NSGraphicsContext.restoreGraphicsState()
        rep.size = target
        let small = NSImage(size: target)
        small.addRepresentation(rep)
        return small
    }
}
