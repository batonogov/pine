import Foundation

// shortcut: single string choices/text only; expand after verified native fixtures require other field types.
/// Strict subset of the ACP form-mode `requestedSchema`. Unknown constraints
/// block the turn; they are never discarded to make an answer appear valid.
/// The schema never carries secrets (ACP forbids form-mode credential
/// collection); URL mode is not advertised and is rejected on receipt.
nonisolated struct KimiACPForm: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    struct Field: Equatable, Sendable {
        let choices: [String]?
        let required: Bool
        let title: String?
        let detail: String?
        let choiceTitles: [String: String]
        let choiceDetails: [String: String]
    }
    let fields: [String: Field]
    let message: String
    var description: String { "<redacted:kimi-form>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["value": description]) }

    init(_ params: [String: AgentEventJSON]) throws {
        guard params["mode"] == .string("form") else {
            throw KimiACPWireError.unsupportedCapability
        }
        message = try KimiACPWire.string(params["message"])
        let schema = try KimiACPWire.object(params["requestedSchema"] ?? .null)
        guard Set(schema.keys).isSubset(of: ["type", "properties", "required"]),
              schema["type"] == .string("object"),
              case .object(let properties) = schema["properties"],
              !properties.isEmpty, properties.count <= 16 else {
            throw KimiACPWireError.unsupportedCapability
        }
        let required: Set<String>
        if let value = schema["required"] {
            guard case .array(let list) = value else { throw KimiACPWireError.unsupportedCapability }
            let keys = try list.map { try KimiACPWire.string($0) }
            guard Set(keys).count == keys.count, Set(keys).isSubset(of: Set(properties.keys)) else {
                throw KimiACPWireError.unsupportedCapability
            }
            required = Set(keys)
        } else { required = [] }
        var parsed: [String: Field] = [:]
        for (key, value) in properties {
            guard key.utf8.count <= 256 else { throw KimiACPWireError.unsupportedCapability }
            _ = try KimiACPWire.string(.string(key))
            let property = try KimiACPWire.object(value)
            guard Set(property.keys).isSubset(of: ["type", "title", "description", "oneOf", "enum"]),
                  property["type"] == .string("string") else {
                throw KimiACPWireError.unsupportedCapability
            }
            let choices: [String]?
            var choiceTitles: [String: String] = [:]
            var choiceDetails: [String: String] = [:]
            if case .array(let options) = property["oneOf"] {
                guard !options.isEmpty, options.count <= 64 else {
                    throw KimiACPWireError.unsupportedCapability
                }
                let values = try options.map { option in
                    let fields = try KimiACPWire.object(option)
                    guard Set(fields.keys).isSubset(of: ["const", "title", "description"]) else {
                        throw KimiACPWireError.unsupportedCapability
                    }
                    let value = try KimiACPWire.string(fields["const"])
                    if let title = fields["title"] {
                        choiceTitles[value] = try KimiACPWire.string(title)
                    }
                    if let detail = fields["description"] {
                        choiceDetails[value] = try KimiACPWire.string(detail)
                    }
                    return value
                }
                guard Set(values).count == values.count else {
                    throw KimiACPWireError.unsupportedCapability
                }
                choices = values
            } else if case .array(let values) = property["enum"] {
                guard !values.isEmpty, values.count <= 64 else {
                    throw KimiACPWireError.unsupportedCapability
                }
                let enumValues = try values.map { try KimiACPWire.string($0) }
                guard Set(enumValues).count == enumValues.count else {
                    throw KimiACPWireError.unsupportedCapability
                }
                choices = enumValues
            } else {
                guard property["oneOf"] == nil, property["enum"] == nil else {
                    throw KimiACPWireError.unsupportedCapability
                }
                choices = nil
            }
            parsed[key] = Field(
                choices: choices, required: required.contains(key),
                title: try property["title"].map { try KimiACPWire.string($0) },
                detail: try property["description"].map { try KimiACPWire.string($0) },
                choiceTitles: choiceTitles, choiceDetails: choiceDetails
            )
        }
        fields = parsed
    }

    /// Validates a user answer against the strict schema. An empty or absent
    /// value is valid only for an optional field; choice values must match.
    func content(answers: [String: [String]]) throws -> AgentEventJSON {
        guard answers.keys.allSatisfy({ key in fields.keys.contains { $0.utf8.elementsEqual(key.utf8) } }) else {
            throw KimiACPWireError.invalidAnswer
        }
        var content: [String: AgentEventJSON] = [:]
        for (key, field) in fields {
            guard let values = answers[key] else {
                guard !field.required else { throw KimiACPWireError.invalidAnswer }
                continue
            }
            guard values.count == 1,
                  !field.required || !values[0].isEmpty,
                  values[0].utf8.count <= 4_096,
                  field.choices.map({ choices in
                      choices.contains { $0.utf8.elementsEqual(values[0].utf8) }
                  }) ?? true else {
                throw KimiACPWireError.invalidAnswer
            }
            content[key] = .string(values[0])
        }
        return .object(content)
    }
}
