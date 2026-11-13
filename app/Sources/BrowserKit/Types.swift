import Foundation

/// One thing an agent asks to do in a web page, as the engine sends it.
public struct BrowserRequest: Sendable {
    public var action: String
    /// For "describe": the action to put into words. Describing changes nothing.
    public var of: String?
    public var url: String?
    public var query: String?
    public var element: Int?
    public var text: String?
    public var submit: Bool
    public var option: String?
    public var dy: Int?
    /// For "upload": the file, which the engine has already checked the agent may use.
    public var path: String?
    /// For "read": where in the page's text to start.
    public var offset: Int?
    /// What this action was described as when it was approved. It is done only if that is still what it would do.
    public var expect: String?
    /// Whose page this is: every conversation has its own.
    public var conversationId: Int

    public init(
        action: String, of: String? = nil, url: String? = nil, query: String? = nil, element: Int? = nil, text: String? = nil, submit: Bool = false,
        option: String? = nil, dy: Int? = nil, path: String? = nil, offset: Int? = nil, expect: String? = nil, conversationId: Int = 0
    ) {
        self.action = action
        self.of = of
        self.url = url
        self.query = query
        self.element = element
        self.text = text
        self.submit = submit
        self.option = option
        self.dy = dy
        self.path = path
        self.offset = offset
        self.expect = expect
        self.conversationId = conversationId
    }
}

/// The answer: text for the model, a short line for the person, and a picture when one was asked for. For "describe"
/// it also says which site the page is on and whether the action would only follow a link.
public struct BrowserReply: Sendable, Error {
    public var ok: Bool
    public var text: String
    public var summary: String?
    public var jpeg: Data?
    public var host: String?
    public var navigates: Bool

    public init(ok: Bool, text: String, summary: String? = nil, jpeg: Data? = nil, host: String? = nil, navigates: Bool = false) {
        self.ok = ok
        self.text = text
        self.summary = summary
        self.jpeg = jpeg
        self.host = host
        self.navigates = navigates
    }

    static func failure(_ text: String) -> BrowserReply { BrowserReply(ok: false, text: text) }
}

/// A browser action as it arrives from the engine, one JSON object: the request, who asks, and the ID to answer under.
public struct BrowserEvent: Decodable, Sendable {
    public let requestId: String
    public let agentName: String?
    public let request: BrowserRequest

    private enum Keys: String, CodingKey {
        case requestId, agentName, action, of, url, query, element, text, submit, option, dy, path, offset, expect, conversationId
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Keys.self)
        requestId = try values.decode(String.self, forKey: .requestId)
        agentName = try values.decodeIfPresent(String.self, forKey: .agentName)
        request = BrowserRequest(
            action: try values.decode(String.self, forKey: .action),
            of: try values.decodeIfPresent(String.self, forKey: .of),
            url: try values.decodeIfPresent(String.self, forKey: .url),
            query: try values.decodeIfPresent(String.self, forKey: .query),
            element: try values.decodeIfPresent(Int.self, forKey: .element),
            text: try values.decodeIfPresent(String.self, forKey: .text),
            submit: try values.decodeIfPresent(Bool.self, forKey: .submit) ?? false,
            option: try values.decodeIfPresent(String.self, forKey: .option),
            dy: try values.decodeIfPresent(Int.self, forKey: .dy),
            path: try values.decodeIfPresent(String.self, forKey: .path),
            offset: try values.decodeIfPresent(Int.self, forKey: .offset),
            expect: try values.decodeIfPresent(String.self, forKey: .expect),
            conversationId: try values.decode(Int.self, forKey: .conversationId)
        )
    }
}

extension BrowserReply {
    /// What the engine's `browser.result` takes as the answer to the request with this ID.
    public func result(for requestId: String) -> [String: Any] {
        var params: [String: Any] = ["requestId": requestId, "ok": ok, "text": text]
        if let summary { params["summary"] = summary }
        if let jpeg { params["image"] = ["data": jpeg.base64EncodedString(), "mimeType": "image/jpeg"] }
        if let host { params["host"] = host }
        if navigates { params["navigates"] = true }
        return params
    }
}

/// Where the browser keeps its cookies and sign-ins.
public enum BrowserProfile: Sendable {
    /// A store of pi²'s own that lasts between launches, apart from Safari's and every other browser's.
    case persistent(UUID)
    /// Nothing is kept once the process ends. For the developer probe, so it never creates or touches a real profile.
    case ephemeral
}

extension String {
    /// Shortened for a line the person or the model reads.
    func clipped(_ limit: Int) -> String {
        let flat = split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }
}
