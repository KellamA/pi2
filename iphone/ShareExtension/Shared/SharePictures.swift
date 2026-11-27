import Foundation
import ImageIO

/// A shared photo made ready to go with a message: drawn afresh (which leaves behind where and with what it was taken),
/// at most 2,000 pixels on its longer side and under the engine's 5 MB, as the conversation's composer and the Mac's
/// `AttachmentReader` prepare one.
struct SharePicture: Equatable, Sendable {
    let name: String
    let data: Data
    let mimeType: String
    let width: Int
    let height: Int
    /// A small PNG, for the page.
    let thumbnail: Data
}

/// Turns a photo's bytes into a picture a message can carry. Run off the main thread: a large photo takes a moment.
///
/// The shared steps are `PictureReader` (`Common/`), with the share's own budget below the engine's 5 MB, for a share
/// with more than one picture to fit the phone's line, a larger thumbnail for the page, and its error in the person's
/// words.
enum SharePictureReader {
    /// The most bytes one picture may take: a little under the engine's limit.
    static let budget = ShareLimits.pictureBytes - 64 * 1024

    static func prepare(_ data: Data, name: String, budget: Int = budget) throws -> SharePicture {
        do {
            let made = try PictureReader.prepare(data, name: name, side: ShareLimits.pictureSide,
                                                 budget: min(budget, Self.budget), rounds: 8, thumbnailSide: 240)
            return SharePicture(name: made.name, data: made.data, mimeType: made.mimeType, width: made.width, height: made.height,
                                thumbnail: made.thumbnail)
        } catch let failure as PictureReader.Failure {
            throw error(failure, name: name)
        }
    }

    static func prepare(_ image: CGImage, name: String, budget: Int = budget) throws -> SharePicture {
        do {
            let made = try PictureReader.prepare(image, name: name, side: ShareLimits.pictureSide,
                                                 budget: budget, rounds: 8, thumbnailSide: 240)
            return SharePicture(name: made.name, data: made.data, mimeType: made.mimeType, width: made.width, height: made.height,
                                thumbnail: made.thumbnail)
        } catch let failure as PictureReader.Failure {
            throw error(failure, name: name)
        }
    }

    private static func error(_ failure: PictureReader.Failure, name: String) -> ShareError {
        switch failure {
        case .unreadable: ShareError("“\(name)” could not be read as a picture.")
        case .unpreparable: ShareError("“\(name)” could not be made small enough to send.")
        }
    }
}
