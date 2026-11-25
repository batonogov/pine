import Foundation

// shortcut: single string choices/text only; expand after verified native fixtures require other field types.
/// Strict ACP v1 form-elicitation subset for the official Claude adapter.
/// Unknown constraints (including unreviewed extension metadata) block the
/// turn; they are never discarded to make an answer appear valid.
nonisolated struct ClaudeCodeACPForm: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    struct Field: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        var description: String { "<redacted:acp-form-field>" }
        var debugDescription: String { description }
        var customMirror: Mirror { Mirror(self, children: ["value": description]) }
        let multiple = false
        let choices: [String]?
        let required: Bool
        let title: String?
        let detail: String?
        let choiceTitles: [String: String]
        let choiceDetails: [String: String]
    }
    let fields: [String: Field]
    let message: String
    var description: String { "<redacted:acp-form>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["value": description]) }

    init(_ params: [String: AgentEventJSON]) throws {
        guard Set(params.keys).isSubset(of: ["mode", "sessionId", "toolCallId", "message", "requestedSchema"]),
              params["mode"] == .string("form") else { throw ClaudeCodeACPError.unsupportedQuestion }
        message = try ClaudeCodeACPWire.string(params["message"])
        let schema = try ClaudeCodeACPWire.object(params["requestedSchema"] ?? .null)
        guard Set(schema.keys).isSubset(of: ["type", "properties", "required"]),
              schema["type"] == .string("object"),
              case .object(let properties) = schema["properties"],
              !properties.isEmpty, properties.count <= 16 else { throw ClaudeCodeACPError.unsupportedQuestion }
        let required: Set<String>
        if let value = schema["required"] {
            guard case .array(let list) = value else { throw ClaudeCodeACPError.unsupportedQuestion }
            let keys = try list.map { try ClaudeCodeACPWire.string($0) }
            guard Set(keys).count == keys.count, Set(keys).isSubset(of: Set(properties.keys)) else {
                throw ClaudeCodeACPError.unsupportedQuestion
            }
            required = Set(keys)
        } else { required = [] }
        var parsed: [String: Field] = [:]
        for (key, value) in properties {
            guard key.utf8.count <= 256 else { throw ClaudeCodeACPError.unsupportedQuestion }
            _ = try ClaudeCodeACPWire.string(.string(key))
            let property = try ClaudeCodeACPWire.object(value)
            guard Set(property.keys).isSubset(of: ["type", "title", "description", "oneOf"]),
                  property["type"] == .string("string") else {
                throw ClaudeCodeACPError.unsupportedQuestion
            }
            let choices: [String]?
            var choiceTitles: [String: String] = [:]
            var choiceDetails: [String: String] = [:]
            if case .array(let options) = property["oneOf"] {
                guard !options.isEmpty, options.count <= 64 else { throw ClaudeCodeACPError.unsupportedQuestion }
                let values = try options.map { option in
                    let fields = try ClaudeCodeACPWire.object(option)
                    guard Set(fields.keys).isSubset(of: ["const", "title", "description"]) else {
                        throw ClaudeCodeACPError.unsupportedQuestion
                    }
                    let value = try ClaudeCodeACPWire.string(fields["const"])
                    if let title = fields["title"] {
                        choiceTitles[value] = try ClaudeCodeACPWire.string(title)
                    }
                    if let detail = fields["description"] {
                        choiceDetails[value] = try ClaudeCodeACPWire.string(detail)
                    }
                    return value
                }
                guard Set(values).count == values.count else { throw ClaudeCodeACPError.unsupportedQuestion }
                choices = values
            } else {
                guard property["oneOf"] == nil else {
                    throw ClaudeCodeACPError.unsupportedQuestion
                }
                choices = nil
            }
            parsed[key] = Field(
                choices: choices, required: required.contains(key),
                title: try property["title"].map { try ClaudeCodeACPWire.string($0) },
                detail: try property["description"].map { try ClaudeCodeACPWire.string($0) },
                choiceTitles: choiceTitles, choiceDetails: choiceDetails
            )
        }
        fields = parsed
    }

    func content(answers: [String: [String]]) throws -> AgentEventJSON {
        guard answers.keys.allSatisfy({ key in fields.keys.contains { $0.utf8.elementsEqual(key.utf8) } }) else {
            throw ClaudeCodeACPError.invalidAnswer
        }
        var content: [String: AgentEventJSON] = [:]
        for (key, field) in fields {
            guard let values = answers[key] else {
                guard !field.required else { throw ClaudeCodeACPError.invalidAnswer }
                continue
            }
            if values.isEmpty {
                guard !field.required else { throw ClaudeCodeACPError.invalidAnswer }
                continue
            }
            guard values.count == 1,
                  !field.required || !values[0].isEmpty,
                  values.allSatisfy({ $0.utf8.count <= 4_096 }),
                  field.choices.map({ choices in
                      choices.contains { $0.utf8.elementsEqual(values[0].utf8) }
                  }) ?? true else {
                throw ClaudeCodeACPError.invalidAnswer
            }
            content[key] = .string(values[0])
        }
        return .object(content)
    }
}
