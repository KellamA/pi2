#if DEBUG
import Foundation
import SwiftUI
import UIKit

/// A debug build's stand-ins for the share page, to draw it without the share sheet, which only a tap opens
/// (docs/iphone-app.md, "What an unsigned simulator build can and cannot do"): what another app might share, and where
/// it might go. Every page drawn from them says it is a sample (`ShareModel.isSample`). None of it is compiled into a
/// release build.
enum ShareSample: String, CaseIterable, Sendable {
    /// A link, as Safari shares a page, to a project's orchestrator.
    case link
    /// A photo, as Photos shares one.
    case photo
    /// A link, with nowhere known to send it: what an unsigned build, or a phone whose app has not reached its Mac,
    /// shows.
    case unknown
    /// A video and a file pi² cannot read beside a photo.
    case problems

    /// What the sample shares, as `ShareItemLoader` would read it.
    var raw: [ShareRaw] {
        switch self {
        case .link, .unknown:
            [.link(URL(string: "https://www.swift.org/blog/")!, title: "Blog · Swift.org")]
        case .photo:
            [.picture(name: "IMG_0412", data: Self.photo())]
        case .problems:
            [
                .picture(name: "IMG_0412", data: Self.photo()),
                .problem("pi² does not send videos or sound. Share a photo, a link, text or a file."),
                .problem("pi² sends pictures, PDFs and text, and “Archive.zip” is none of them."),
            ]
        }
    }

    /// Where the sample may go: two sample projects and a chat, labelled as samples; none for `unknown`.
    var destinations: ShareDestinations? {
        guard self != .unknown else { return nil }
        return ShareDestinations(writtenAt: Date(), macName: "Sample Mac", destinations: [
            ShareDestination(conversation: 9, kind: .orchestrator, title: "Sample project", project: "Sample project"),
            ShareDestination(conversation: 12, kind: .agent, title: "Time the walkthrough", project: "Sample project"),
            ShareDestination(conversation: 139, kind: .orchestrator, title: "Sample project 2", project: "Sample project 2"),
            ShareDestination(conversation: 201, kind: .chat, title: "Sample chat", project: nil),
        ])
    }

    /// The page as the sample draws it, with the sample's words typed.
    @MainActor
    func model() async -> ShareModel {
        let model = ShareModel(drop: nil, isSample: true)
        model.showSample(destinations)
        if self == .link { model.instructions = "Read this and file an issue for what we should try." }
        await model.prepare(raw)
        return model
    }

    /// A photo drawn here, 3,000 by 2,000 pixels, as a camera's JPEG: large enough to be scaled down as a real one is.
    static func photo() -> Data {
        let size = CGSize(width: 3000, height: 2000)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let colors = [UIColor(red: 0.98, green: 0.72, blue: 0.45, alpha: 1).cgColor, UIColor(red: 0.36, green: 0.38, blue: 0.91, alpha: 1).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            UIColor(white: 1, alpha: 0.85).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 2100, y: 300, width: 420, height: 420))
            UIColor(red: 0.2, green: 0.25, blue: 0.4, alpha: 1).setFill()
            context.cgContext.fill(CGRect(x: 0, y: 1500, width: size.width, height: 500))
        }
        return image.jpegData(compressionQuality: 0.95) ?? Data()
    }
}

/// The share page drawn in the app from a sample, for a debug launch (`PI2_SHOW=share:<sample>`, once `App/` routes
/// it) and for the tests' pictures. Its buttons close nothing.
struct ShareSampleScreen: View {
    let sample: ShareSample
    @State private var model: ShareModel?

    var body: some View {
        Group {
            if let model {
                SharePage(model: model) { _ in }
            } else {
                ProgressView()
            }
        }
        .task { model = await sample.model() }
    }
}
#endif
