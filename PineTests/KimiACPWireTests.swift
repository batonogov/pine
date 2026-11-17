import Foundation
import Testing
@testable import Pine

struct KimiACPWireTests {
    private let fullMatrix: AgentEventJSON = .object([
        "protocolVersion": .number("1"),
        "agentInfo": .object([
            "name": .string("Kimi Code CLI"),
            "version": .string(KimiACPCapabilities.pinnedCLIVersion)
        ]),
        "agentCapabilities": .object([
            "loadSession": .bool(true),
            "promptCapabilities": .object([
                "image": .bool(true), "audio": .bool(false), "embeddedContext": .bool(true)
            ]),
            "sessionCapabilities": .object([
                "list": .object([:]), "resume": .object([:]), "close": .object([:]),
                "delete": .object([:]), "fork": .object([:]),
                "additionalDirectories": .object([:])
            ]),
            "mcpCapabilities": .object(["http": .bool(true), "sse": .bool(true)]),
            "auth": .object(["logout": .object([:])])
        ]),
        "authMethods": .array([.object(["id": .string("login"), "name": .string("Kimi login")])])
    ])

    @Test func encodeAlwaysCarriesJSONRPCVersionAndNewline() throws {
        let message = CodexAppServerMessage.request(.integer(7), method: "session/prompt",
                                                    params: .object(["a": .string("b")]))
        let bytes = try KimiACPWire.encode(message)
        #expect(bytes.last == 10)
        let fields = try KimiACPWire.object(
            AgentEventJSONParser(data: bytes.dropLast()).parse()
        )
        #expect(fields["jsonrpc"] == .string("2.0"))
        #expect(fields["method"] == .string("session/prompt"))
        // Round-trips through the shared parser.
        _ = try CodexAppServerMessage(data: bytes)
    }

    @Test func encodeRejectsFramesAboveTheSharedFramerLimit() throws {
        let payload = String(repeating: "x", count: KimiACPWire.maximumFrameBytes)
        let message = CodexAppServerMessage.request(.integer(1), method: "session/prompt",
                                                    params: .object(["text": .string(payload)]))
        #expect(throws: KimiACPWireError.capacity) {
            _ = try KimiACPWire.encode(message)
        }
    }

    @Test func agentIdentityParsesDocumentedMatrix() throws {
        let identity = try KimiACPAgentIdentity(response: fullMatrix,
                                                agentName: "Kimi Code CLI",
                                                pinnedVersion: KimiACPCapabilities.pinnedCLIVersion)
        #expect(identity.capabilities.loadSession)
        #expect(identity.capabilities.image)
        #expect(identity.capabilities.embeddedContext)
        #expect(identity.capabilities.sessionResume)
        #expect(identity.capabilities.sessionFork)
        #expect(identity.capabilities.additionalDirectories)
        #expect(!identity.capabilities.audio)
        #expect(identity.requiresAuthentication)
        #expect(identity.authMethodCount == 1)
        #expect(!String(reflecting: identity).contains("login"))
    }

    @Test func agentIdentityRejectsWrongProtocolVersionAgentAndFloor() throws {
        func replaced(_ root: AgentEventJSON) throws -> AgentEventJSON {
            var fields = try KimiACPWire.object(root)
            fields["protocolVersion"] = .number("2")
            return .object(fields)
        }
        #expect(throws: KimiACPWireError.self) {
            _ = try KimiACPAgentIdentity(response: try replaced(fullMatrix),
                                         agentName: "Kimi Code CLI",
                                         pinnedVersion: KimiACPCapabilities.pinnedCLIVersion)
        }
        var fields = try KimiACPWire.object(fullMatrix)
        var agent = try KimiACPWire.object(fields["agentInfo"] ?? .null)
        agent["name"] = .string("Other Agent")
        fields["agentInfo"] = .object(agent)
        #expect(throws: KimiACPWireError.self) {
            _ = try KimiACPAgentIdentity(response: .object(fields), agentName: "Kimi Code CLI",
                                         pinnedVersion: KimiACPCapabilities.pinnedCLIVersion)
        }
        agent["version"] = .string("2.1.1")
        fields["agentInfo"] = .object(agent)
        #expect(throws: KimiACPWireError.self) {
            _ = try KimiACPAgentIdentity(response: .object(fields), agentName: "Kimi Code CLI",
                                         pinnedVersion: KimiACPCapabilities.pinnedCLIVersion)
        }
    }

    @Test func agentIdentityWithoutAuthMethodsIsExternalProvider() throws {
        var fields = try KimiACPWire.object(fullMatrix)
        fields["authMethods"] = .array([])
        let identity = try KimiACPAgentIdentity(
            response: .object(fields), agentName: "Kimi Code CLI",
            pinnedVersion: KimiACPCapabilities.pinnedCLIVersion
        )
        #expect(!identity.requiresAuthentication)
    }

    @Test func configOptionsParseKnownAndUnknownTypesGracefully() throws {
        let options = try KimiACPConfigOptions.parse(.array([
            .object(["id": .string("mode"), "type": .string("select")]),
            .object(["id": .string("brave"), "type": .string("boolean")]),
            .object(["id": .string("future"), "type": .string("pine_future_type")])
        ]))
        #expect(options.map(\.kind) == [.select, .boolean, .unknown])
        #expect(try KimiACPConfigOptions.parse(nil).isEmpty)
        #expect(try KimiACPConfigOptions.parse(.null).isEmpty)
        #expect(throws: KimiACPWireError.self) {
            _ = try KimiACPConfigOptions.parse(.object([:]))
        }
    }

    @Test func configOptionsRejectUnboundedArrays() throws {
        let options = (0...KimiACPConfigOptions.maximumOptions).map { index in
            AgentEventJSON.object(["id": .string("opt\(index)"), "type": .string("select")])
        }
        #expect(throws: KimiACPWireError.capacity) {
            _ = try KimiACPConfigOptions.parse(.array(options))
        }
    }

    @Test func sessionIDValidation() {
        #expect(KimiACPWire.validSessionID("kimi_fixture_new"))
        #expect(KimiACPWire.validSessionID("01HZABCXYZ-123"))
        #expect(!KimiACPWire.validSessionID(""))
        #expect(!KimiACPWire.validSessionID(String(repeating: "a", count: 257)))
        #expect(!KimiACPWire.validSessionID("bad\u{01}id"))
        #expect(!KimiACPWire.validSessionID("path/to/session"))
    }

    @Test func promptContentValidatesAgainstObservedCapabilities() throws {
        let capabilities = try KimiACPAgentIdentity(
            response: fullMatrix, agentName: "Kimi Code CLI",
            pinnedVersion: KimiACPCapabilities.pinnedCLIVersion
        ).capabilities
        let textOnly = try KimiACPPromptContent(text: "Fixture instruction")
        #expect(try textOnly.blocks(capabilities: capabilities).count == 1)
        let withImage = try KimiACPPromptContent(
            text: "Fixture instruction",
            images: [.init(mimeType: "image/png", data: Data([1, 2, 3]))]
        )
        #expect(try withImage.blocks(capabilities: capabilities).count == 2)
        let limited = try KimiACPAgentIdentity(
            response: limitedMatrix, agentName: "Kimi Code CLI",
            pinnedVersion: KimiACPCapabilities.pinnedCLIVersion
        )
        #expect(throws: KimiACPWireError.unsupportedCapability) {
            _ = try withImage.blocks(capabilities: limited.capabilities)
        }
        let withResource = try KimiACPPromptContent(
            text: "Fixture instruction",
            resources: [.init(uri: "file:///fixture/doc.md", text: "Fixture doc")]
        )
        #expect(throws: KimiACPWireError.unsupportedCapability) {
            _ = try withResource.blocks(capabilities: limited.capabilities)
        }
    }

    private let limitedMatrix: AgentEventJSON = .object([
        "protocolVersion": .number("1"),
        "agentInfo": .object([
            "name": .string("Kimi Code CLI"),
            "version": .string(KimiACPCapabilities.pinnedCLIVersion)
        ]),
        "agentCapabilities": .object([
            "loadSession": .bool(false),
            "promptCapabilities": .object([
                "image": .bool(false), "audio": .bool(false), "embeddedContext": .bool(false)
            ]),
            "sessionCapabilities": .object([:])
        ]),
        "authMethods": .array([])
    ])

    @Test func blobResourcesCannotBeConstructed() {
        // Kimi drops blob resources (no text) with a warn only; the content
        // model refuses them before submission instead.
        #expect(throws: KimiACPWireError.self) {
            _ = try KimiACPPromptContent(
                text: "Fixture instruction",
                resources: [.init(uri: "file:///fixture/blob.bin", text: "")]
            )
        }
    }

    @Test func promptContentBounds() {
        #expect(throws: KimiACPWireError.self) {
            _ = try KimiACPPromptContent(text: "")
        }
        #expect(throws: KimiACPWireError.self) {
            _ = try KimiACPPromptContent(text: String(repeating: "x",
                                                      count: KimiACPPromptContent.maximumTextBytes + 1))
        }
        #expect(throws: KimiACPWireError.capacity) {
            _ = try KimiACPPromptContent(
                text: "Fixture instruction",
                images: (0...KimiACPPromptContent.maximumImages).map { _ in
                    .init(mimeType: "image/png", data: Data([1]))
                }
            )
        }
        // Joint cap: 4 × 200 KB raw images (each under the per-image bound)
        // exceed the 900 KB total, so the frame cannot exceed 1 MB at encode.
        #expect(throws: KimiACPWireError.capacity) {
            _ = try KimiACPPromptContent(
                text: "Fixture instruction",
                images: Array(repeating: KimiACPPromptContent.Image(
                    mimeType: "image/png", data: Data(repeating: 1, count: 200 * 1_024)
                ), count: 4)
            )
        }
    }
}
