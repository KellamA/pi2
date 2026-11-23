import Foundation

/// What a value of the models holds, written out as text that is the same on every run and every Mac: every stored
/// property, in the order the type declares them, found by reflection so that a field added to a model is written with
/// nothing more to do here; dictionaries and sets in a sorted order; and, for the types that have them, the computed
/// properties the views read (`Computed`). Type names are written without their module, so that the same models give
/// the same text whether they are compiled into this program or come from `PiModels`.
enum Dump {
    static func text(_ value: Any) -> String {
        // Unwrap an optional before the cast below: an Optional holding a Computed passes it, writing the computed part twice (#867).
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let wrapped = mirror.children.first else { return "nil" }
            return text(wrapped.value)
        }
        if let computed = value as? Computed {
            return plain(value) + " => {" + computed.computed.map { "\($0.0): \(text($0.1))" }.joined(separator: ", ") + "}"
        }
        return plain(value)
    }

    /// The stored properties alone, for a computed property that is a model of the same type (`AgentProfile.asSaved`).
    static func plain(_ value: Any) -> String {
        switch value {
        case let string as String: return quoted(string)
        case let number as Double: return "\(number)"
        case let number as Int: return "\(number)"
        case let bool as Bool: return bool ? "true" : "false"
        case let raw as Raw: return raw.text
        default: break
        }
        let mirror = Mirror(reflecting: value)
        switch mirror.displayStyle {
        case .optional:
            guard let wrapped = mirror.children.first else { return "nil" }
            return text(wrapped.value)
        case .collection:
            return "[" + mirror.children.map { text($0.value) }.joined(separator: ", ") + "]"
        case .set:
            return "{" + mirror.children.map { text($0.value) }.sorted().joined(separator: ", ") + "}"
        case .dictionary:
            let pairs = mirror.children.map { pair -> (String, String) in
                let parts = Array(Mirror(reflecting: pair.value).children)
                return (text(parts[0].value), text(parts[1].value))
            }
            return "[" + pairs.sorted { $0.0 < $1.0 }.map { "\($0.0): \($0.1)" }.joined(separator: ", ") + "]"
        case .enum:
            guard let payload = mirror.children.first else { return ".\(value)" }
            return ".\(payload.label ?? "?")(\(text(payload.value)))"
        case .tuple:
            return "(" + mirror.children.map { child in
                child.label.map { $0.hasPrefix(".") ? text(child.value) : "\($0): \(text(child.value))" } ?? text(child.value)
            }.joined(separator: ", ") + ")"
        case .struct, .class:
            let name = String(describing: type(of: value))
            return name + "(" + mirror.children.map { "\($0.label ?? "?"): \(text($0.value))" }.joined(separator: ", ") + ")"
        default:
            return String(describing: value)
        }
    }

    /// A string as JSON writes it, so that a line break or a quote in it cannot be mistaken for the dump's own.
    static func quoted(_ string: String) -> String {
        var result = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case _ where scalar.value < 0x20: result += String(format: "\\u%04x", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    /// A dictionary as JSON, with sorted keys: what a model's `payload` for a request is.
    static func json(_ object: Any) -> Raw {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return Raw(text: "not JSON") }
        return Raw(text: String(decoding: data, as: UTF8.self))
    }
}

/// Text already written out, written as it is.
struct Raw {
    let text: String
}

/// The computed properties of a model that the views read, written after its stored ones. Only those that depend on
/// nothing but the model: none that read the clock, the time zone or the language, which differ from one Mac to the next.
protocol Computed {
    var computed: [(String, Any)] { get }
}
