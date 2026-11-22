import Foundation

/// What the engine keeps about an attachment of a sent message.
public struct AttachmentNote: Codable, Equatable, Sendable {
    public let name: String
    /// "image" or "text".
    public let kind: String
    /// In bytes.
    public let size: Int
}
