import Foundation
import Testing
@testable import Pine

@Suite("ClaudeCode ACP form boundary")
struct ClaudeCodeACPFormTests {
    @Test func singleChoiceKeepsLabelsAndRejectsMissingForeignAndMultipleAnswers() throws {
        let form = try ClaudeCodeACPForm(params(property: .object([
            "type": .string("string"), "title": .string("Color"),
            "oneOf": .array([.object(["const": .string("id-blue"), "title": .string("Blue")])])
        ])))
        #expect(form.fields["choice"]?.choiceTitles["id-blue"] == "Blue")
        #expect(try form.content(answers: ["choice": ["id-blue"]]) == .object(["choice": .string("id-blue")]))
        for answers in [[:], ["choice": ["foreign"]], ["choice": ["id-blue", "id-blue"]], ["extra": ["id-blue"]]] {
            #expect(throws: ClaudeCodeACPError.invalidAnswer) { _ = try form.content(answers: answers) }
        }
        #expect(!String(reflecting: form).contains("id-blue"))
        var fieldDiagnostic = ""
        dump(try #require(form.fields["choice"]), to: &fieldDiagnostic)
        #expect(!fieldDiagnostic.contains("id-blue") && !fieldDiagnostic.contains("Blue"))
    }

    @Test func unsupportedConstraintsAndModesAreNeverSilentlyDiscarded() throws {
        for property: AgentEventJSON in [
            .object(["type": .string("string"), "pattern": .string("^safe$")]),
            .object(["type": .string("boolean")]),
            .object(["type": .string("array"), "oneOf": .array([]),
                     "items": .object(["type": .string("string")])])
        ] {
            #expect(throws: ClaudeCodeACPError.unsupportedQuestion) { _ = try ClaudeCodeACPForm(params(property: property)) }
        }
        var invalid = params(property: .object(["type": .string("string")]))
        invalid["mode"] = .string("url")
        #expect(throws: ClaudeCodeACPError.unsupportedQuestion) { _ = try ClaudeCodeACPForm(invalid) }
        invalid = params(property: .object(["type": .string("string")]))
        var schema = try ClaudeCodeACPWire.object(invalid["requestedSchema"] ?? .null)
        schema["properties"] = .object([
            "choice": .object(["type": .string("string")]),
            "optionalUnsupported": .object(["type": .string("boolean")])
        ])
        invalid["requestedSchema"] = .object(schema)
        #expect(throws: ClaudeCodeACPError.unsupportedQuestion) { _ = try ClaudeCodeACPForm(invalid) }
        invalid = params(property: .object(["type": .string("string")]))
        invalid["_meta"] = .object(["unreviewed": .bool(true)])
        #expect(throws: ClaudeCodeACPError.unsupportedQuestion) { _ = try ClaudeCodeACPForm(invalid) }
    }

    @Test func nativeOptionalCustomFieldIsLiteralAndNeverAnInventedOption() throws {
        var fields = params(property: .object([
            "type": .string("string"), "oneOf": .array([.object(["const": .string("blue")])])
        ]))
        var schema = try ClaudeCodeACPWire.object(fields["requestedSchema"] ?? .null)
        var properties = try ClaudeCodeACPWire.object(schema["properties"] ?? .null)
        properties["choice_custom"] = .object(["type": .string("string"), "title": .string("Other")])
        schema["properties"] = .object(properties)
        schema["required"] = .array([])
        fields["requestedSchema"] = .object(schema)
        let form = try ClaudeCodeACPForm(fields)
        #expect(try form.content(answers: ["choice": ["blue"], "choice_custom": []]) == .object([
            "choice": .string("blue")
        ]))
        #expect(try form.content(answers: ["choice_custom": ["my choice"]]) == .object([
            "choice_custom": .string("my choice")
        ]))
        #expect(throws: ClaudeCodeACPError.invalidAnswer) {
            _ = try form.content(answers: ["choice": ["my choice"]])
        }
    }

    @Test func optionAndSessionIdentifiersRequireExactUTF8NotDisplayEquivalence() throws {
        let form = try ClaudeCodeACPForm(params(property: .object([
            "type": .string("string"), "oneOf": .array([.object(["const": .string("Café")])])
        ])))
        #expect(throws: ClaudeCodeACPError.invalidAnswer) {
            _ = try form.content(answers: ["choice": ["Cafe\u{301}"]])
        }
        #expect(try form.content(answers: ["choice": ["Café"]]) == .object(["choice": .string("Café")]))
        #expect(!ClaudeCodeACPWire.matches(.string("ses_K"), string: "ses_K"))
    }

    @Test func boundsAndDiagnosticsDoNotLeakAnswers() throws {
        let form = try ClaudeCodeACPForm(params(property: .object(["type": .string("string")])))
        #expect(throws: ClaudeCodeACPError.invalidAnswer) {
            _ = try form.content(answers: ["choice": [String(repeating: "x", count: 4_097)]])
        }
        var diagnostic = ""
        dump(form, to: &diagnostic)
        #expect(!diagnostic.contains("private-message"))
        let bytes = try ClaudeCodeACPWire.encode(.notification(method: "session/cancel", params: .object([:])))
        var parser = AgentEventJSONParser(data: bytes)
        #expect(try ClaudeCodeACPWire.object(parser.parse())["jsonrpc"] == .string("2.0"))
    }

    @Test func sharedFramingRequiresACPVersionWithoutChangingCodexDefault() throws {
        let versionless = Data(#"{"method":"session/update","params":{}}"#.utf8)
        #expect(throws: CodexAppServerWireError.invalidEnvelope) {
            _ = try CodexAppServerMessage(data: versionless, requireJSONRPCVersion: true)
        }
        #expect(try CodexAppServerMessage(data: versionless) == .notification(
            method: "session/update", params: .object([:])
        ))
        var framer = CodexAppServerFramer(requireJSONRPCVersion: true)
        var frame = versionless
        frame.append(10)
        #expect(throws: CodexAppServerWireError.invalidEnvelope) { try framer.receive(frame) { _ in } }
        #expect(framer.isClosed)
    }

    private func params(property: AgentEventJSON) -> [String: AgentEventJSON] {
        [
            "mode": .string("form"), "message": .string("private-message"),
            "requestedSchema": .object([
                "type": .string("object"), "required": .array([.string("choice")]),
                "properties": .object(["choice": property])
            ])
        ]
    }
}
