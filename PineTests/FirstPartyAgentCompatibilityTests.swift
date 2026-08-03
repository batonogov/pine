import Foundation
import Testing
@testable import Pine

@MainActor
struct FirstPartyAgentCompatibilityTests {
    private struct Fixture: Decodable {
        let schemaVersion: UInt16
        let agents: [AgentFixture]
    }

    private struct AgentFixture: Decodable {
        let stableIdentifier: String
        let testedVersion: String
        let commands: [String]
    }

    private struct ProtocolReviewFixture: Decodable {
        struct Agent: Decodable {
            struct Case: Decodable {
                let name: String
                let inputBytes: Int
                let wire: String
            }

            let stableIdentifier: String
            let authority: String
            let interface: String
            let cases: [Case]
        }

        let schemaVersion: UInt16
        let maximumEventBytes: Int
        let sanitization: String
        let agents: [Agent]
    }

    @Test func catalogIsCompleteUniqueAndFailClosed() throws {
        let records = FirstPartyAgentCompatibilityCatalog.records
        #expect(records.count == 12)
        #expect(Set(records.map(\.stableIdentifier)).count == records.count)
        #expect(records.allSatisfy { $0.schemaVersion == FirstPartyAgentCompatibilityCatalog.schemaVersion })
        #expect(records.allSatisfy { $0.supportTier == .detected })
        #expect(records.allSatisfy { $0.eventSource == .processSnapshot })
        #expect(records.allSatisfy { $0.trustLevel == .observedProcessGeneration })
        #expect(records.allSatisfy { $0.resumeCapability == .newSessionOnly })
        #expect(records.allSatisfy { $0.notificationAccuracy == .processTerminationOnly })

        let aliases = records.flatMap(\.executableAliases)
        #expect(Set(aliases).count == aliases.count)
        #expect(Set(records.map(\.stableIdentifier)) == AgentPresentationCatalog.builtInStableIdentifiers)
        for record in records {
            #expect(!record.testedVersions.isEmpty)
            #expect(record.upstreamURL.hasPrefix("https://"))
            let agentType = try #require(AgentType(stableIdentifier: record.stableIdentifier))
            #expect(agentType.stableIdentifier == record.stableIdentifier)
            #expect(agentType.cliNames == record.executableAliases)
            for alias in record.executableAliases {
                #expect(AgentPresentationCatalog.stableIdentifier(forExecutableAlias: alias) == record.stableIdentifier)
            }
        }
    }

    @Test func reviewedStructuredInterfacesRemainFailClosed() throws {
        let fixture = try loadProtocolReviewFixture()
        #expect(fixture.schemaVersion == FirstPartyAgentCompatibilityCatalog.schemaVersion)
        #expect(fixture.maximumEventBytes == 65_536)
        #expect(fixture.sanitization.contains("credentials"))
        #expect(Set(fixture.agents.map(\.stableIdentifier)) == [
            "amp", "cursorAgent", "goose", "qwenCode", "crush",
        ])

        let requiredCases: [String: Set<String>] = [
            "amp": ["documented-init", "documented-completion", "malformed", "reordered", "oversized", "future-schema"],
            "cursorAgent": ["version", "json", "stream-json", "resume-explicit", "malformed", "oversized", "future-schema"],
            "goose": ["negotiation", "ordering", "replay", "malformed", "oversized", "future-schema"],
            "qwenCode": ["version", "process", "documented-stream", "malformed", "reordered", "oversized", "future-schema"],
            "crush": ["session", "reconnect", "duplicate", "reordered", "malformed", "oversized", "future-schema"],
        ]

        for agent in fixture.agents {
            let record = try #require(
                FirstPartyAgentCompatibilityCatalog.record(stableIdentifier: agent.stableIdentifier)
            )
            #expect(record.supportTier == .detected)
            #expect(record.eventSource == .processSnapshot)
            #expect(record.trustLevel == .observedProcessGeneration)
            #expect(record.launchCapability == .manualTerminal)
            #expect(record.resumeCapability == .newSessionOnly)
            #expect(agent.authority == "pine-launched-authenticated-transport-only")
            #expect(!agent.interface.isEmpty)
            #expect(Set(agent.cases.map(\.name)) == requiredCases[agent.stableIdentifier])
            #expect(agent.cases.first { $0.name == "oversized" }?.inputBytes == fixture.maximumEventBytes + 1)
            #expect(agent.cases.allSatisfy { !$0.wire.localizedCaseInsensitiveContains("token") })
            #expect(agent.cases.allSatisfy { !$0.wire.localizedCaseInsensitiveContains("prompt") })
        }
    }

    @Test func sanitizedVersionedFixturesConformToCatalogAndDetector() throws {
        let fixture = try loadFixture()
        #expect(fixture.schemaVersion == FirstPartyAgentCompatibilityCatalog.schemaVersion)
        #expect(fixture.agents.count == FirstPartyAgentCompatibilityCatalog.records.count)

        for agent in fixture.agents {
            let record = try #require(
                FirstPartyAgentCompatibilityCatalog.record(stableIdentifier: agent.stableIdentifier)
            )
            #expect(record.testedVersions.contains(agent.testedVersion))
            #expect(!agent.commands.isEmpty)
            for command in agent.commands {
                #expect(!command.localizedCaseInsensitiveContains("token"))
                #expect(!command.localizedCaseInsensitiveContains("secret"))
                let executable = AgentDetector.extractExecutableName(from: command)
                #expect(
                    AgentPresentationCatalog.stableIdentifier(forExecutableAlias: executable.lowercased())
                        == agent.stableIdentifier
                )
            }
        }
    }

    @Test func unknownAndLookalikeCommandsStayGeneric() {
        for command in ["gemini-server", "opencode-helper", "claude-code", "server.js"] {
            let executable = AgentDetector.extractExecutableName(from: command)
            let resolved = AgentType.resolve(fromProcessName: executable)
            guard let resolved, case .generic(let name) = resolved else {
                Issue.record("Expected generic fallback for \(command)")
                continue
            }
            #expect(name == executable)
        }
    }

    @Test func documentationMatchesCatalogAndReleaseNotesLinkIt() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let matrix = try String(
            contentsOf: sourceRoot.appending(path: "docs/agent-compatibility.md"),
            encoding: .utf8
        )
        let releaseNotes = try String(
            contentsOf: sourceRoot.appending(path: "docs/pine-2.0-release-notes.md"),
            encoding: .utf8
        )
        let releaseMatrix = try String(
            contentsOf: sourceRoot.appending(path: "docs/pine-2.0-agent-release-matrix.md"),
            encoding: .utf8
        )

        for record in FirstPartyAgentCompatibilityCatalog.records {
            #expect(matrix.contains(record.displayName))
            for version in record.testedVersions {
                #expect(matrix.contains(version))
            }
        }
        for followUp in 1316...1320 {
            #expect(matrix.contains("issues/\(followUp)"))
        }
        #expect(releaseNotes.contains("(agent-compatibility.md)"))
        #expect(releaseNotes.contains("(pine-2.0-agent-release-matrix.md)"))
        #expect(matrix.contains("(pine-2.0-agent-release-matrix.md)"))
        #expect(releaseMatrix.contains("macOS 26"))
        #expect(releaseMatrix.contains("macOS 27"))
        for record in FirstPartyAgentCompatibilityCatalog.records {
            #expect(releaseMatrix.contains(record.displayName))
        }
    }

    private func loadFixture() throws -> Fixture {
        let source = URL(fileURLWithPath: #filePath)
        let fixtureURL = source.deletingLastPathComponent()
            .appending(path: "Fixtures/AgentAdapters/process-v1.json")
        let data = try Data(contentsOf: fixtureURL)
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    private func loadProtocolReviewFixture() throws -> ProtocolReviewFixture {
        let source = URL(fileURLWithPath: #filePath)
        let fixtureURL = source.deletingLastPathComponent()
            .appending(path: "Fixtures/AgentAdapters/protocol-review-v1.json")
        let data = try Data(contentsOf: fixtureURL)
        return try JSONDecoder().decode(ProtocolReviewFixture.self, from: data)
    }
}
