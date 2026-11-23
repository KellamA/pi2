import Foundation
import ImageIO
import PiModels
import SwiftUI
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import pi2

/// The share extension (#702), through `ShareExtension/Shared/`, which the app builds too: reading what another app
/// shared, scaling a photo, the message and its draft, the folder the extension and the app share, the app's pickup,
/// and the page's model. The extension's own entry, `ShareViewController`, only hosts the page.
@MainActor
struct ShareTests {
    // MARK: Reading what was shared

    @Test func aLinkFromSafariIsALink() async throws {
        let url = try #require(URL(string: "https://www.swift.org/blog/"))
        let raw = await ShareItemLoader.load([NSItemProvider(object: url as NSURL)], title: "Blog · Swift.org")
        #expect(raw == [.link(url, title: "Blog · Swift.org")])
    }

    @Test func theSameAddressAsTextIsNotSaidTwice() async throws {
        let url = try #require(URL(string: "https://example.com/a"))
        let raw = await ShareItemLoader.load([NSItemProvider(object: url as NSURL), NSItemProvider(object: "https://example.com/a" as NSString)])
        #expect(raw == [.link(url, title: nil)])
    }

    @Test func textIsText() async {
        let raw = await ShareItemLoader.load([NSItemProvider(object: "Remember the milk" as NSString)])
        #expect(raw == [.text("Remember the milk")])
    }

    @Test func aPhotoIsReadWithItsName() async throws {
        let data = ShareSample.photo()
        let provider = NSItemProvider(item: data as NSData, typeIdentifier: UTType.jpeg.identifier)
        provider.suggestedName = "IMG_0412"
        let raw = await ShareItemLoader.load([provider])
        #expect(raw == [.picture(name: "IMG_0412", data: data)])
    }

    @Test func aTextFileGoesAsItsText() async throws {
        let provider = NSItemProvider(item: Data("line one\nline two\n".utf8) as NSData, typeIdentifier: UTType.plainText.identifier)
        provider.suggestedName = "notes.txt"
        #expect(await ShareItemLoader.load([provider]) == [.file(name: "notes.txt", text: "line one\nline two\n")])
    }

    @Test func aFileByItsAddressIsRead() async throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "plan.md")
        try Data("# The plan\n".utf8).write(to: file)
        #expect(await ShareItemLoader.load([NSItemProvider(object: file as NSURL)]) == [.file(name: "plan.md", text: "# The plan\n")])
    }

    @Test func aVideoAndABinaryFileAreRefusedWithWhy() async throws {
        let video = NSItemProvider(item: Data([0, 0, 0, 24]) as NSData, typeIdentifier: UTType.mpeg4Movie.identifier)
        let binary = NSItemProvider(item: Data([0x50, 0x4B, 0x03, 0x04, 0, 0, 1]) as NSData, typeIdentifier: UTType.zip.identifier)
        binary.suggestedName = "Archive.zip"
        let raw = await ShareItemLoader.load([video, binary])
        #expect(raw == [
            .problem("pi² does not send videos or sound. Share a photo, a link, text or a file."),
            .problem("pi² sends pictures, PDFs and text, and “Archive.zip” is none of them."),
        ])
    }

    @Test func aPDFGoesAsItsTextAndAScanIsRefused() throws {
        let text = ShareItemLoader.classify(Self.pdf(text: "The quarterly figures, in words a reader can follow."), name: "Report.pdf", type: .pdf)
        guard case .file(let name, let words) = text else { Issue.record("not a file: \(text)"); return }
        #expect(name == "Report.pdf")
        #expect(words.contains("quarterly figures"))
        #expect(ShareItemLoader.classify(Self.pdf(text: nil), name: "Scan.pdf", type: .pdf)
            == .problem("“Scan.pdf” has no text pi² can read: it may be a scan. Share its pages as photos instead."))
    }

    @Test func aTextTooLongIsRefused() {
        let long = String(repeating: "a", count: ShareLimits.textCharacters + 1)
        guard case .problem(let why) = ShareItemLoader.checked(long, name: "big.txt") else { Issue.record("not refused"); return }
        #expect(why.hasPrefix("“big.txt” is too long"))
    }

    // MARK: Scaling a photo

    @Test func aLargePhotoIsMadeSmallEnough() throws {
        let picture = try SharePictureReader.prepare(ShareSample.photo(), name: "Photo")
        #expect(max(picture.width, picture.height) == ShareLimits.pictureSide)
        #expect(picture.data.count <= ShareLimits.pictureBytes)
        #expect(picture.mimeType == "image/jpeg")
        let source = try #require(CGImageSourceCreateWithData(picture.data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(max(image.width, image.height) <= ShareLimits.pictureSide)
        #expect(!picture.thumbnail.isEmpty)
    }

    @Test func aPhotoKeepsToTheBudgetItIsGiven() throws {
        let picture = try SharePictureReader.prepare(Self.noise(width: 1800, height: 1200), name: "Photo", budget: 150_000)
        #expect(picture.data.count <= 150_000)
    }

    @Test func notAPictureSaysSo() {
        #expect(throws: ShareError.self) { try SharePictureReader.prepare(Data("not a picture".utf8), name: "x") }
    }

    @Test func picturesShareThePhonesLine() throws {
        let noisy = Self.noise(width: 2000, height: 2000)
        let content = ShareContent.prepare([.picture(name: "A", data: noisy), .picture(name: "B", data: noisy), .picture(name: "C", data: noisy)])
        let pictures = content.pieces.compactMap { if case .picture(let picture) = $0 { picture } else { nil } }
        #expect(pictures.count == 3)
        // Base64 on the line: all three together under the share's limit, each under the engine's 5 MB.
        let encoded = pictures.reduce(0) { $0 + ($1.data.count + 2) / 3 * 4 }
        #expect(encoded < ShareLimits.messageBytes)
        #expect(pictures.allSatisfy { $0.data.count <= ShareLimits.pictureBytes })
    }

    @Test func noMoreThanTenAttachments() {
        let files = (1...12).map { ShareRaw.file(name: "\($0).txt", text: "text \($0)") }
        let content = ShareContent.prepare(files)
        #expect(content.pieces.filter { if case .file = $0 { true } else { false } }.count == 10)
        #expect(content.problems == ["A message carries at most 10 attachments; the rest were left out."])
    }

    // MARK: The message and its draft

    @Test func theMessageHoldsTheInstructionsThenWhatWasShared() throws {
        let url = try #require(URL(string: "https://www.swift.org/blog/"))
        let long = String(repeating: "word ", count: 1_000)
        let picture = SharePicture(name: "IMG_1", data: Data([1, 2, 3]), mimeType: "image/jpeg", width: 1, height: 1, thumbnail: Data())
        let content = ShareContent(pieces: [.link(url, title: "Blog · Swift.org"), .text("A short note"), .text(long), .picture(picture), .problem("left out")])
        let message = try #require(ShareMessage.compose(instructions: "  Read this  ", content: content))
        #expect(message.text == "Read this\n\nBlog · Swift.org\nhttps://www.swift.org/blog/\n\nA short note")
        #expect(message.attachments == [.text(name: "Shared text", text: long), .picture(name: "IMG_1", mimeType: "image/jpeg", data: Data([1, 2, 3]))])
        #expect(ShareMessage.compose(instructions: " ", content: ShareContent(pieces: [.problem("x")])) == nil)
    }

    @Test func theDraftIsTheSubmitTheMacTakes() throws {
        let draft = ShareDraft(writtenAt: Date(), destination: Self.orchestrator, text: "Look", attachments: [
            .picture(name: "IMG_1", mimeType: "image/png", data: Data([1, 2, 3])), .text(name: "notes.txt", text: "abc"),
        ])
        let params = draft.submitParameters
        #expect(params["id"] as? Int == 9)
        #expect(params["text"] as? String == "Look")
        #expect(params["requestId"] as? String == draft.id)
        #expect(params["mode"] == nil)
        let attachments = try #require(params["attachments"] as? [[String: Any]])
        #expect(attachments.count == 2)
        #expect(attachments[0]["kind"] as? String == "image")
        #expect(attachments[0]["mimeType"] as? String == "image/png")
        #expect(attachments[0]["data"] as? String == Data([1, 2, 3]).base64EncodedString())
        #expect(attachments[1]["kind"] as? String == "text")
        #expect(attachments[1]["text"] as? String == "abc")
        #expect(!draft.mayWaitInMailbox)

        let words = ShareDraft(writtenAt: Date(), destination: Self.orchestrator, text: "Look", attachments: [])
        #expect(words.submitParameters["attachments"] == nil)
        #expect(words.mayWaitInMailbox)
        #expect(!ShareDraft(writtenAt: Date(), destination: Self.orchestrator, text: String(repeating: "a", count: 4_001), attachments: []).mayWaitInMailbox)
    }

    @Test func aDraftIsKeptWholeInTheSharedFolder() throws {
        let drop = ShareDrop(folder: Self.folder())
        defer { drop.wipe() }
        let first = ShareDraft(writtenAt: Date(timeIntervalSince1970: 1_000), destination: Self.orchestrator, text: "one", attachments: [.picture(name: "P", mimeType: "image/jpeg", data: Data([9, 8, 7]))])
        let second = ShareDraft(writtenAt: Date(timeIntervalSince1970: 2_000), destination: Self.chat, text: "two", attachments: [])
        try drop.add(second)
        try drop.add(first)
        #expect(drop.all() == [first, second])

        let file = drop.folder.appending(path: "Drafts/\(first.id).json")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect(attributes[.protectionKey] as? FileProtectionType == .complete)
        #expect(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)

        // A file that is not a draft's is passed over.
        try Data("{}".utf8).write(to: drop.folder.appending(path: "Drafts/\(UUID().uuidString).json"))
        try Data("x".utf8).write(to: drop.folder.appending(path: "Drafts/stray.json"))
        #expect(drop.all() == [first, second])

        drop.remove(first.id)
        #expect(drop.all() == [second])
        drop.wipe()
        #expect(!FileManager.default.fileExists(atPath: drop.folder.path))
    }

    @Test func theFolderHoldsTenDraftsAtMost() throws {
        let drop = ShareDrop(folder: Self.folder())
        defer { drop.wipe() }
        for index in 0..<ShareLimits.drafts {
            try drop.add(ShareDraft(writtenAt: Date(), destination: Self.orchestrator, text: "\(index)", attachments: []))
        }
        #expect(throws: ShareError("pi² already holds 10 shares waiting to go to your Mac. Open pi² so it can send them, then share this again.")) {
            try drop.add(ShareDraft(writtenAt: Date(), destination: Self.orchestrator, text: "one more", attachments: []))
        }
    }

    // MARK: Where a share can go

    @Test func theListIsOrchestratorsThenAgentsThenChats() throws {
        let projects = try JSONDecoder().decode([ProjectRow].self, from: Data("""
        [{"id":"p1","name":"Atlas","orchestratorId":"o1","conversation":9},
         {"id":"p2","name":"Not started","orchestratorId":"o2"},
         {"id":"p3","name":"Archived","orchestratorId":"o3","conversation":30,"archivedAt":5}]
        """.utf8))
        let conversations = try JSONDecoder().decode([ConversationSummary].self, from: Data("""
        [{"id":9,"title":"Atlas","updatedAt":50,"busy":false,"projectId":"p1","orchestrator":"current"},
         {"id":10,"title":"Older agent","updatedAt":10,"busy":false,"projectId":"p1"},
         {"id":11,"title":"Newer agent","updatedAt":40,"busy":false,"projectId":"p1"},
         {"id":12,"title":"A sub-chat","updatedAt":45,"busy":false,"projectId":"p1","parent":9},
         {"id":13,"title":"Earlier orchestrator","updatedAt":5,"busy":false,"projectId":"p1","orchestrator":"earlier"},
         {"id":20,"title":"A chat","updatedAt":30,"busy":false,"chat":true}]
        """.utf8))
        let list = ShareDestinations.make(projects: projects, conversations: conversations, macName: "Studio", at: Date(timeIntervalSince1970: 0))
        #expect(list.macName == "Studio")
        #expect(list.destinations.map(\.conversation) == [9, 11, 10, 20])
        #expect(list.destinations.map(\.kind) == [.orchestrator, .agent, .agent, .chat])
        #expect(list.destinations[0].label == "Atlas’s orchestrator")
        #expect(list.destinations[1].detail == "Agent in Atlas")
    }

    @Test func theListTheAppWroteIsReadUntilItIsAWeekOld() throws {
        let drop = ShareDrop(folder: Self.folder())
        defer { drop.wipe() }
        let written = Date(timeIntervalSince1970: 1_000_000)
        let list = ShareDestinations(writtenAt: written, macName: nil, destinations: [Self.orchestrator, Self.chat])
        #expect(drop.destinations(at: written) == nil)
        try drop.writeDestinations(list)
        #expect(drop.destinations(at: written.addingTimeInterval(6 * 86_400)) == list)
        #expect(drop.destinations(at: written.addingTimeInterval(8 * 86_400)) == nil)
    }

    // MARK: The app's pickup

    @Test func thePickupSendsOldestFirstAndKeepsWhatWasRefused() async throws {
        let drop = ShareDrop(folder: Self.folder())
        defer { drop.wipe() }
        let now = Date()
        let refused = ShareDraft(writtenAt: now.addingTimeInterval(-30), destination: Self.orchestrator, text: "refused", attachments: [])
        let taken = ShareDraft(writtenAt: now.addingTimeInterval(-20), destination: Self.orchestrator, text: "taken", attachments: [])
        let late = ShareDraft(writtenAt: now.addingTimeInterval(-2 * 86_400), destination: Self.chat, text: "late", attachments: [])
        for draft in [refused, taken, late] { try drop.add(draft) }
        let sender = StandInSender(answers: ["refused": .refused("The conversation is archived."), "taken": .taken])

        let report = await SharePickup.run(drop, through: sender, now: now)
        #expect(report == SharePickup.Report(taken: [taken.id], notSent: [late.id, refused.id]))
        #expect(sender.handed == ["refused", "taken"])
        #expect(drop.all().map(\.state) == [.notSent(ShareDraft.tooLate), .notSent("The conversation is archived.")])
        #expect(drop.notSent.map(\.id) == [late.id, refused.id])

        // Not sent again.
        #expect(await SharePickup.run(drop, through: sender, now: now) == SharePickup.Report())
    }

    @Test func thePickupStopsAtWhatCannotGoYet() async throws {
        let drop = ShareDrop(folder: Self.folder())
        defer { drop.wipe() }
        let now = Date()
        let photo = ShareDraft(writtenAt: now.addingTimeInterval(-20), destination: Self.orchestrator, text: "photo", attachments: [.picture(name: "P", mimeType: "image/jpeg", data: Data([1]))])
        let words = ShareDraft(writtenAt: now.addingTimeInterval(-10), destination: Self.orchestrator, text: "words", attachments: [])
        for draft in [photo, words] { try drop.add(draft) }
        let sender = StandInSender(answers: ["photo": .unreachable("Your Mac can’t be reached."), "words": .kept])

        let report = await SharePickup.run(drop, through: sender, now: now)
        #expect(report.stopped == "Your Mac can’t be reached.")
        #expect(sender.handed == ["photo"])
        #expect(drop.all() == [photo, words])

        sender.answers["photo"] = .taken
        #expect(await SharePickup.run(drop, through: sender, now: now) == SharePickup.Report(taken: [photo.id], kept: [words.id]))
        #expect(drop.all().isEmpty)
    }

    // MARK: The page

    @Test func withoutAListThePageSendsNothing() async {
        let model = ShareModel(drop: nil)
        #expect(model.destinations == nil)
        await model.prepare([.text("hello")])
        #expect(!model.canSend)
        #expect(!model.send())

        let empty = ShareDrop(folder: Self.folder())
        let unknown = ShareModel(drop: empty)
        #expect(unknown.destinations == nil)
    }

    @Test func sendWritesTheDraftAndRemembersWhereItWent() async throws {
        let drop = ShareDrop(folder: Self.folder())
        defer { drop.wipe() }
        try drop.writeDestinations(ShareDestinations(writtenAt: Date(), macName: "Studio", destinations: [Self.orchestrator, Self.chat]))
        let model = ShareModel(drop: drop)
        #expect(model.choice == Self.orchestrator)
        let url = try #require(URL(string: "https://example.com/page"))
        await model.prepare([.link(url, title: nil), .picture(name: "IMG_2", data: ShareSample.photo())])
        model.choice = Self.chat
        model.instructions = "What is this?"
        #expect(model.canSend)
        #expect(model.send())

        let draft = try #require(drop.all().first)
        #expect(draft.destination == Self.chat)
        #expect(draft.text == "What is this?\n\nhttps://example.com/page")
        #expect(draft.attachments.map(\.name) == ["IMG_2"])
        #expect(draft.encodedSize <= ShareLimits.messageBytes)
        #expect(ShareModel(drop: drop).choice == Self.chat)
    }

    @Test func onlyProblemsCannotBeSent() async throws {
        let drop = ShareDrop(folder: Self.folder())
        defer { drop.wipe() }
        try drop.writeDestinations(ShareDestinations(writtenAt: Date(), macName: nil, destinations: [Self.orchestrator]))
        let model = ShareModel(drop: drop)
        await model.prepare([.problem("pi² does not send videos or sound. Share a photo, a link, text or a file.")])
        #expect(model.holdBack == "Nothing here can be sent.")
        #expect(!model.canSend)
    }

    // MARK: Pictures of the page

    /// Draws the page from each sample, light and dark and at the largest text size, into the folder
    /// `PI2_SHARE_SHOTS` names (`TEST_RUNNER_PI2_SHARE_SHOTS` given to `xcodebuild test`): the share sheet opens only
    /// with a tap, which nothing here can give. Without it, the pages are drawn and nothing is written.
    @Test func picturesOfThePage() async throws {
        let folder = ProcessInfo.processInfo.environment["PI2_SHARE_SHOTS"].map { URL(filePath: $0, directoryHint: .isDirectory) }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        if let folder { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let looks: [(String, UIUserInterfaceStyle, UIContentSizeCategory)] = [
            ("light", .light, .large), ("dark", .dark, .large), ("largest", .light, .accessibilityExtraExtraExtraLarge),
        ]
        for sample in ShareSample.allCases {
            for (look, style, size) in looks {
                if folder == nil, look != "light" { continue }
                let model = await sample.model()
                let page = UIHostingController(rootView: SharePage(model: model) { _ in })
                page.traitOverrides.preferredContentSizeCategory = size
                let window = UIWindow(windowScene: scene)
                window.overrideUserInterfaceStyle = style
                window.rootViewController = page
                window.makeKeyAndVisible()
                defer { window.isHidden = true }
                // For the picture only: a moment for the form to lay itself out. Nothing is checked against time.
                try await Task.sleep(for: .milliseconds(600))
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                if let folder, let png = image.pngData() {
                    try png.write(to: folder.appending(path: "\(sample.rawValue)-\(look).png"))
                }
            }
        }
    }

    // MARK: Helpers

    static let orchestrator = ShareDestination(conversation: 9, kind: .orchestrator, title: "Atlas", project: "Atlas")
    static let chat = ShareDestination(conversation: 20, kind: .chat, title: "A chat", project: nil)

    static func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "share-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    /// A picture of random pixels, which no encoder makes small: the hardest a budget can be kept to.
    static func noise(width: Int, height: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for index in pixels.indices where index % 4 != 3 { pixels[index] = UInt8.random(in: 0...255, using: &generator) }
        let image = pixels.withUnsafeMutableBytes { buffer -> CGImage? in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
        }
        let data = NSMutableData()
        if let image, let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
        return data as Data
    }

    /// A one-page PDF with `text` on it, or with only a drawn shape, as a scan has no text.
    static func pdf(text: String?) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { context in
            context.beginPage()
            if let text {
                (text as NSString).draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
            } else {
                UIColor.gray.setFill()
                context.fill(CGRect(x: 72, y: 72, width: 200, height: 100))
            }
        }
    }
}

/// Stands in for the app's sender: answers by the draft's text, and notes what it was handed.
@MainActor
final class StandInSender: ShareDraftSender {
    var answers: [String: ShareDelivery]
    private(set) var handed: [String] = []

    init(answers: [String: ShareDelivery]) {
        self.answers = answers
    }

    func deliver(_ draft: ShareDraft) async -> ShareDelivery {
        handed.append(draft.text)
        return answers[draft.text] ?? .refused("not expected")
    }
}
