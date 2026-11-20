import Foundation
import Testing
@testable import Pine

// MARK: - Fixture corpus

struct KimiACPFixtureCorpus: Decodable {
    struct Agent: Decodable {
        let stableIdentifier: String
        let executableAliases: [String]
        let authority: String
        let interface: String
        let agentName: String
        let protocolVersion: Int
        let pinnedCLIVersion: String
        let versionFloors: [String: String]
        let unimplementedAgentMethods: [String]
        let reverseRPCsNotOwned: [String]
        let cases: [Case]
    }
    struct Case: Decodable {
        let name: String
        let direction: String
        let expect: String
        let wire: String
        let inputBytes: Int?
    }
    let schemaVersion: Int
    let fixtureVersion: String
    let sanitization: String
    let agent: Agent
}

@Suite("Kimi ACP fixture corpus")
struct KimiACPFixtureCorpusTests {
    private let marker = "FIXTURE_SECRET_MARKER"

    private func loadFixture() throws -> KimiACPFixtureCorpus {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/AgentAdapters/kimi-acp-v1.json")
        return try JSONDecoder().decode(KimiACPFixtureCorpus.self, from: Data(contentsOf: url))
    }

    @Test func corpusIsSanitizedAndFloorConsistent() throws {
        let corpus = try loadFixture()
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/AgentAdapters/kimi-acp-v1.json")
        let fixtureRaw = try String(contentsOf: fixtureURL, encoding: .utf8) ?? ""
        let markerCount = fixtureRaw.components(separatedBy: marker).count - 1
        #expect(markerCount == 1)
        #expect(!fixtureRaw.contains("Bearer "))
        #expect(!fixtureRaw.contains("sk-"))
        #expect(corpus.agent.stableIdentifier == "kimiCode")
        #expect(corpus.agent.pinnedCLIVersion == KimiACPCapabilities.pinnedCLIVersion)
        #expect(corpus.agent.versionFloors == KimiACPCapabilities.versionFloors)
        #expect(!corpus.agent.versionFloors.isEmpty)
        #expect(corpus.agent.versionFloors.values.allSatisfy {
            $0 == KimiACPCapabilities.pinnedCLIVersion
        })
        #expect(corpus.agent.unimplementedAgentMethods == KimiACPCapabilities.unimplementedAgentMethods)
        #expect(corpus.agent.reverseRPCsNotOwned == KimiACPCapabilities.reverseRPCsNotOwned)
    }

    @Test func initializeAndStopReasonWiresDriveTheCodecAndState() async throws {
        let corpus = try loadFixture()
        for (index, fixtureCase) in corpus.agent.cases.enumerated() {
            guard fixtureCase.direction == "agent", !fixtureCase.wire.isEmpty else { continue }
            switch fixtureCase.name {
            case "documented-initialize", "initialize-no-auth-methods":
                let message = try decode(fixtureCase.wire)
                guard case .response(let id, let result) = message else {
                    Issue.record("Case \(index) must be an initialize response"); continue
                }
                let identity = try? KimiACPAgentIdentity(
                    response: result, agentName: corpus.agent.agentName,
                    pinnedVersion: corpus.agent.pinnedCLIVersion
                )
                #expect(identity != nil)
                if fixtureCase.name == "initialize-no-auth-methods" {
                    #expect(identity?.requiresAuthentication == false)
                } else {
                    #expect(identity?.requiresAuthentication == true)
                    _ = id
                }
            case "initialize-wrong-protocol-version", "initialize-wrong-agent-name",
                 "initialize-below-version-floor":
                let message = try decode(fixtureCase.wire)
                guard case .response(_, let result) = message else {
                    Issue.record("Case \(index) must be an initialize response"); continue
                }
                #expect(throws: KimiACPWireError.self) {
                    _ = try KimiACPAgentIdentity(
                        response: result, agentName: corpus.agent.agentName,
                        pinnedVersion: corpus.agent.pinnedCLIVersion
                    )
                }
            case "session-new-with-unknown-config-option":
                let message = try decode(fixtureCase.wire)
                guard case .response(_, let result) = message else {
                    Issue.record("Case \(index) must be a session result"); continue
                }
                let fields = try KimiACPWire.object(result)
                let options = try KimiACPConfigOptions.parse(fields["configOptions"])
                #expect(options.map(\.kind) == [.select, .unknown])
            default:
                break // Handled by the state-machine and wire-shape corpora.
            }
        }
        _ = try await stateMachineCorpus(corpus)
    }

    /// The four declared wire-shape cases (`expect: "rejected"`) are driven
    /// through the shared framer so their behavior is asserted, not declared.
    @Test func declaredWireShapeCasesDriveTheSharedFramer() throws {
        let corpus = try loadFixture()
        for name in ["malformed-frame", "empty-wire", "oversized-frame",
                     "foreign-jsonrpc-version"] {
            let fixtureCase = try #require(corpus.agent.cases.first { $0.name == name })
            #expect(fixtureCase.expect == "rejected", "Case \(name) must be rejected")
            switch name {
            case "malformed-frame":
                // An unterminated object is not a frame: the shared framer
                // fences ingress on the parse failure.
                var framer = CodexAppServerFramer()
                #expect((try? framer.receive(Data((fixtureCase.wire + "\n").utf8)) { _ in }) == nil)
                #expect(framer.isClosed)
            case "empty-wire":
                // Empty wire = clean channel end: a finished framer with no
                // partial frame does not throw; nothing was delivered.
                var framer = CodexAppServerFramer()
                #expect((try? framer.finish()) != nil)
                #expect(framer.isClosed)
            case "oversized-frame":
                // 1048577 bytes > the 1 MiB shared frame cap: the framer
                // fences with a capacity-class error.
                var framer = CodexAppServerFramer()
                #expect(throws: CodexAppServerWireError.self) {
                    try framer.receive(Data(repeating: 120, count: fixtureCase.inputBytes ?? 0)) { _ in }
                }
                #expect(framer.isClosed)
            case "foreign-jsonrpc-version":
                // jsonrpc 3.0 is not the ACP v1 envelope: invalid envelope.
                var framer = CodexAppServerFramer()
                #expect(throws: CodexAppServerWireError.self) {
                    try framer.receive(Data((fixtureCase.wire + "\n").utf8)) { _ in }
                }
                #expect(framer.isClosed)
            default:
                break
            }
        }
    }

    private func stateMachineCorpus(_ corpus: KimiACPFixtureCorpus) async throws -> Bool {
        let stopExpectation: [String: KimiACPSession.State] = [
            "stop-reason-end-turn": .unverified,
            "stop-reason-cancelled": .cancelled,
            "stop-reason-unrecognized": .unknown,
            "prompt-failure": .failed
        ]
        for (name, expected) in stopExpectation {
            // A missing case is a recorded failure, not a silent skip.
            let wire = try #require(corpus.agent.cases.first { $0.name == name }?.wire)
            let options = KimiFixtureOptions()
            let made: KimiTestFixture?
            do {
                made = try await KimiTestFixture.make(options: options) { _ in .accepted }
            } catch {
                Issue.record("Case \(name) fixture creation failed: \(error)")
                made = nil
            }
            guard let fixture = made else { continue }
            do {
                try await fixture.session.start()
                _ = try await fixture.concrete.submit(KimiACPPromptContent(text: "Fixture instruction"))
                if name == "stop-reason-cancelled" {
                    try await fixture.concrete.cancel()
                }
                let message = try CodexAppServerMessage(data: Data((wire + "\n").utf8))
                fixture.transport.push(message)
                let deadline = ContinuousClock.now.advanced(by: .seconds(10))
                var settled: KimiACPSession.Snapshot?
                while ContinuousClock.now < deadline {
                    let snapshot = await fixture.concrete.snapshot()
                    if snapshot.state == expected { settled = snapshot; break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(settled?.state == expected, "Case \(name) must settle \(expected)")
            } catch {
                Issue.record("Case \(name) failed to run: \(type(of: error))")
            }
            await fixture.session.stop(deadline: .now.advanced(by: .seconds(1)))
        }
        return true
    }

    private func decode(_ wire: String) throws -> CodexAppServerMessage {
        try CodexAppServerMessage(data: Data(wire.utf8))
    }
}

// MARK: - Version floor documentation

@Suite("Kimi ACP version floor documentation")
struct KimiACPVersionFloorDocTests {
    @Test func compatibilityDocRecordsStructuredFloor() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let matrix = try String(
            contentsOf: sourceRoot.appending(path: "docs/agent-compatibility.md"),
            encoding: .utf8
        )
        #expect(matrix.contains("2.6.2"))
        #expect(matrix.contains("Kimi Code CLI"))
        #expect(matrix.contains("session/request_permission"))
        #expect(matrix.contains("elicitation/create"))
        #expect(matrix.contains("blob"))
        #expect(matrix.contains("session/fork"))
        for (capability, floor) in KimiACPCapabilities.versionFloors {
            #expect(matrix.contains(capability), "Missing floor for \(capability)")
            _ = floor
        }
    }
}
