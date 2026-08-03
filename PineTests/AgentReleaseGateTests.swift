import Foundation
import Testing
@testable import Pine

@Suite("Pine 2.0 agent release gates", .serialized)
struct AgentReleaseGateTests {
    private struct Fixture: Decodable {
        let schemaVersion: UInt16
        let fixtureVersion: String
        let sanitization: String
        let agents: [AgentFixture]
        let fakeExecutable: FakeExecutableFixture
    }

    private struct AgentFixture: Decodable {
        let stableIdentifier: String
        let testedVersion: String
        let commands: [String]
    }

    private struct FakeExecutableFixture: Decodable {
        let protocolVersion: UInt16
        let scenarios: [Scenario]
    }

    private struct Scenario: Decodable {
        let name: String
        let expectedExitStatus: Int32
        let expectedStates: [String]
        let malformed: Bool?
        let minimumDelayMilliseconds: Int?
        let expectedGenerations: [UInt64]?
        let expectedProcessIdentifiers: [Int32]?
    }

    private struct FakeEnvelope: Decodable {
        let schemaVersion: UInt16
        let scenario: String
        let events: [FakeEvent]
    }

    private struct FakeEvent: Decodable {
        let state: String
        let pid: Int32
        let generation: UInt64
    }

    private struct Execution {
        let status: Int32
        let output: Data
        let errorOutput: String
        let elapsed: Duration
    }

    @Test("every first-party adapter passes the same detected-tier contract")
    func firstPartyConformanceAndFallback() throws {
        let fixture = try loadFixture()
        let fixtureIDs = Set(fixture.agents.map(\.stableIdentifier))
        let records = FirstPartyAgentCompatibilityCatalog.records

        #expect(fixture.schemaVersion == FirstPartyAgentCompatibilityCatalog.schemaVersion)
        #expect(fixture.fakeExecutable.protocolVersion == fixture.schemaVersion)
        #expect(fixtureIDs == Set(records.map(\.stableIdentifier)))

        for record in records {
            let agent = try #require(
                fixture.agents.first { $0.stableIdentifier == record.stableIdentifier }
            )
            #expect(record.supportTier == .detected)
            #expect(record.eventSource == .processSnapshot)
            #expect(record.trustLevel == .observedProcessGeneration)
            #expect(record.testedVersions.contains(agent.testedVersion))

            for command in agent.commands {
                let executable = AgentDetector.extractExecutableName(from: command)
                #expect(
                    AgentPresentationCatalog.stableIdentifier(
                        forExecutableAlias: executable.lowercased()
                    ) == record.stableIdentifier
                )
            }

            for lookalike in record.executableAliases.map({ "\($0)-helper" }) {
                let resolved = AgentType.resolve(fromProcessName: lookalike)
                guard case .generic = resolved else {
                    Issue.record("Expected generic fallback for \(lookalike)")
                    continue
                }
            }
        }
    }

    @Test("fake executable covers lifecycle, malformed, delayed, and replacement cases")
    func fakeExecutableScenarios() throws {
        let fixture = try loadFixture()
        let names = Set(fixture.fakeExecutable.scenarios.map(\.name))
        #expect(names == [
            "working", "waiting", "completion", "failure", "malformed",
            "delayed", "pid-reuse", "process-replacement",
        ])

        for scenario in fixture.fakeExecutable.scenarios {
            let execution = try executeFakeAgent(scenario: scenario.name)
            #expect(execution.status == scenario.expectedExitStatus)
            #expect(execution.errorOutput.isEmpty)

            if scenario.malformed == true {
                #expect(throws: DecodingError.self) {
                    _ = try JSONDecoder().decode(
                        FakeEnvelope.self,
                        from: execution.output
                    )
                }
                continue
            }

            let envelope = try JSONDecoder().decode(
                FakeEnvelope.self,
                from: execution.output
            )
            #expect(envelope.schemaVersion == fixture.fakeExecutable.protocolVersion)
            #expect(envelope.scenario == scenario.name)
            #expect(envelope.events.map(\.state) == scenario.expectedStates)
            if let expected = scenario.expectedGenerations {
                #expect(envelope.events.map(\.generation) == expected)
            }
            if let expected = scenario.expectedProcessIdentifiers {
                #expect(envelope.events.map(\.pid) == expected)
            }
            if let minimumDelayMilliseconds = scenario.minimumDelayMilliseconds {
                #expect(
                    execution.elapsed >= .milliseconds(minimumDelayMilliseconds)
                )
                #expect(execution.elapsed < .seconds(2))
            }
        }
    }

    @Test("fixtures and fake executable are offline and privacy bounded")
    func offlineSanitizedFixture() throws {
        let fixture = try loadFixture()
        let fixtureData = try Data(contentsOf: fixtureURL)
        let fixtureText = try #require(String(data: fixtureData, encoding: .utf8))
        let scriptText = try String(contentsOf: fakeAgentURL, encoding: .utf8)
        let combined = fixtureText + scriptText

        #expect(!fixture.fixtureVersion.isEmpty)
        #expect(fixture.sanitization.contains("no prompts"))
        for forbidden in [
            "api_key", "authorization:", "bearer ", "BEGIN PRIVATE KEY",
            "/Users/", "$HOME", "curl ", "wget ", "nc ", "ssh ",
        ] {
            #expect(!combined.localizedCaseInsensitiveContains(forbidden))
        }
    }

    @Test("hostile identifiers, paths, cursors, and manifests fail closed")
    func securityCorpus() throws {
        for identifier in ["../codex", "CODEX", "cоdex", "agent\u{202E}txt"] {
            #expect(throws: Error.self) {
                _ = try AgentID(validating: identifier)
            }
        }
        for path in ["../secret", "/private/secret", "safe/../secret", "safe\u{0}file"] {
            #expect(throws: AdapterCandidateError.invalidRelativePath) {
                _ = try CandidateFileChange(operation: .modify, relativePath: path)
            }
        }
        for cursor in ["", "cursor\nvalue", String(repeating: "x", count: 257)] {
            #expect(throws: AdapterValueError.self) {
                _ = try AdapterResumePosition(cursor)
            }
        }
        #expect(throws: AdapterValueError.self) {
            _ = try UserAgentPresentationRegistration(
                identifier: "trusted", displayName: "Spoof\u{202E}txt",
                executableAliases: ["codex"]
            )
        }
    }

    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/AgentAdapters/process-v1.json")
    }

    private var fakeAgentURL: URL {
        fixtureURL.deletingLastPathComponent().appending(path: "fake-agent.sh")
    }

    private func loadFixture() throws -> Fixture {
        try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL))
    }

    private func executeFakeAgent(scenario: String) throws -> Execution {
        let process = Process()
        let output = Pipe()
        let errorOutput = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [fakeAgentURL.path, scenario]
        process.environment = ["LANG": "C", "PATH": "/usr/bin:/bin"]
        process.standardOutput = output
        process.standardError = errorOutput

        let clock = ContinuousClock()
        let startedAt = clock.now
        try process.run()
        process.waitUntilExit()
        return Execution(
            status: process.terminationStatus,
            output: output.fileHandleForReading.readDataToEndOfFile(),
            errorOutput: String(
                data: errorOutput.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "",
            elapsed: startedAt.duration(to: clock.now)
        )
    }
}
