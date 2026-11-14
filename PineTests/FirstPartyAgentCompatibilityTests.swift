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
        #expect(records.count == 18)
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
        // Every presentation/reservation record must also be resolvable
        // through the legacy migration path: `builtIn` throws when the ID is
        // missing from the `AgentID` legacy allowlist and returns nil when it
        // is missing from the built-in presentation table, so a drift between
        // the two coupled records fails here.
        for stableIdentifier in AgentPresentationCatalog.builtInStableIdentifiers {
            _ = try #require(
                try AgentPresentationCatalog.builtIn(stableIdentifier: stableIdentifier)
            )
        }
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
        for command in [
            "gemini-server", "opencode-helper", "claude-code", "server.js",
            "agy-cli", "antigravity", "droid-cli", "factory", "cline-code",
            "grok-build", "kilo-code", "kilocode-helper",
            "xgrok", "grok2", "notclined", "kilocode-backup",
            "/usr/local/bin/my-grok",
        ] {
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

    @Test func retiredLegacyFixturePreservesUnrelatedRecordsWithoutAuthority() throws {
        struct LegacyFixture: Decodable {
            let history: [AgentHistoryEntry]
            let descriptors: [AgentDescriptor]
        }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/AgentAdapters/retired-empryo-v1.json")
        let fixture = try JSONDecoder().decode(LegacyFixture.self, from: Data(contentsOf: url))
        #expect(fixture.history.count == 2)
        #expect(fixture.history.map(\.agentTypeRaw) == ["empryo", "codex"])
        #expect(fixture.history[0].attribution == .heuristic)
        #expect(fixture.history[0].verifiedChangeSet == nil)
        #expect(fixture.descriptors.map(\.typeIdentifier) == ["empryo", "codex", "future-agent"])
        #expect(fixture.descriptors[0].agentType == .generic(name: "Empry⊙"))
        #expect(fixture.descriptors[0].isRetired)
        #expect(!fixture.descriptors[1].isRetired)
        #expect(fixture.descriptors[2].agentType == .generic(name: "future-agent"))
        let data = try JSONEncoder().encode(fixture.descriptors)
        #expect(try JSONDecoder().decode([AgentDescriptor].self, from: data) == fixture.descriptors)
    }

    @Test func retiredEmpryoIsHistoricalMetadataOnly() throws {
        #expect(FirstPartyAgentCompatibilityCatalog.record(stableIdentifier: "empryo") == nil)
        #expect(AgentPresentationCatalog.stableIdentifier(forExecutableAlias: "empryo") == nil)
        #expect(try AgentPresentationCatalog.builtIn(stableIdentifier: "empryo") == nil)
        #expect(AgentType(stableIdentifier: "empryo") == .generic(name: "Empry⊙"))
        #expect(AgentType.resolve(fromProcessName: "empryo") == .generic(name: "empryo"))
        let migrations = try LegacyAgentMigrationCatalog(
            stableIdentifiers: ["empryo", "codex", "generic:Custom"]
        )
        let retired = try #require(migrations.lookup(stableIdentifier: "empryo"))
        #expect(retired.canonicalAgentID.value == "empryo")
        #expect(retired.presentation.displayName == "Empry⊙")
        #expect(retired.presentation.style == .generic)
        #expect(retired.presentation.executableAliases.isEmpty)
        #expect(migrations.lookup(stableIdentifier: "codex") != nil)
        #expect(migrations.lookup(stableIdentifier: "generic:Custom") != nil)
        let namesake = try LegacyAgentMigrationCatalog(stableIdentifiers: ["empryo", "generic:Empry⊙"])
        #expect(namesake.lookup(stableIdentifier: "empryo")?.canonicalAgentID
            != namesake.lookup(stableIdentifier: "generic:Empry⊙")?.canonicalAgentID)
        let registry = try AgentAdapterRegistry(compiledPresentations: [], compiledAdapters: [])
        let registration = try UserAgentPresentationRegistration(
            identifier: "other", displayName: "Empry⊙", executableAliases: ["empryo"]
        )
        #expect(throws: (any Error).self) {
            try registry.validatedUserPresentations([registration])
        }
        for (id, aliases) in [("empryo", [String]()), ("user:other", ["empryo"])] {
            let descriptor = try AgentPresentationDescriptor(
                agentID: AgentID(validating: id), displayName: "Other",
                executableAliases: Set(try aliases.map(ExecutableAlias.init(validating:))), style: .generic
            )
            #expect(throws: (any Error).self) {
                try AgentPresentationCatalog.validateReservedNames(descriptor)
            }
        }
    }

    @Test func newDetectedAgentsResolveAndPersistWithoutClaimingStructuredEvents() throws {
        let agents: [(
            stableIdentifier: String,
            displayName: String,
            commands: [String],
            lookalikes: [String]
        )] = [
            (
                "antigravity", "Antigravity",
                ["agy", "/opt/homebrew/bin/agy -p --output-format json"],
                ["agy-cli", "antigravity"]
            ),
            (
                "droid", "Droid",
                ["droid", "node /opt/homebrew/bin/droid", "/opt/homebrew/bin/droid exec -o json"],
                ["droid-cli", "factory"]
            ),
            (
                "cline", "Cline",
                ["cline", "node /usr/local/bin/cline --json", "/opt/homebrew/bin/cline --acp"],
                ["cline-code", "cline-helper", "notclined"]
            ),
            (
                "grokBuild", "Grok Build",
                ["grok", "/opt/homebrew/bin/grok -p --output-format json"],
                ["grok-build", "grok-helper", "xgrok", "grok2", "/usr/local/bin/my-grok"]
            ),
            (
                "kiloCode", "Kilo Code",
                ["kilo", "kilocode", "bun /opt/homebrew/bin/kilo run --auto", "/opt/homebrew/bin/kilo acp"],
                ["kilo-code", "kilocode-helper", "kilocode-backup"]
            ),
        ]

        for agent in agents {
            for command in agent.commands {
                let executable = AgentDetector.extractExecutableName(from: command)
                let type = try #require(AgentType.resolve(fromProcessName: executable))
                #expect(type.stableIdentifier == agent.stableIdentifier)
                #expect(type.displayName == agent.displayName)
                #expect(AgentType(stableIdentifier: type.stableIdentifier) == type)
            }
            let record = try #require(
                FirstPartyAgentCompatibilityCatalog.record(
                    stableIdentifier: agent.stableIdentifier
                )
            )
            #expect(!record.executableAliases.isEmpty)
            for alias in record.executableAliases {
                #expect(
                    AgentPresentationCatalog.stableIdentifier(
                        forExecutableAlias: alias
                    ) == agent.stableIdentifier
                )
                let type = try #require(AgentType.resolve(fromProcessName: alias))
                #expect(type.stableIdentifier == agent.stableIdentifier)
                #expect(type.displayName == agent.displayName)
            }
            #expect(record.notificationAccuracy == .processTerminationOnly)
            #expect(record.supportTier == .detected)
            #expect(record.eventSource == .processSnapshot)
            #expect(record.resumeCapability == .newSessionOnly)
            let presentation = try #require(
                try AgentPresentationCatalog.builtIn(
                    stableIdentifier: agent.stableIdentifier
                )
            )
            try AgentPresentationCatalog.validateBuiltIn(presentation)
            #expect(presentation.displayName == agent.displayName)
            for lookalike in agent.lookalikes {
                #expect(AgentType.resolve(fromProcessName: lookalike) == .generic(name: lookalike))
            }
        }
    }

    @Test func kiloCodeDoesNotShareOpenCodeExecutableIdentity() {
        // Kilo is an OpenCode fork, but its installed executables are `kilo`
        // and `kilocode`. The `opencode` executable must keep resolving to the
        // OpenCode agent instead of leaking into Kilo Code.
        #expect(AgentType.resolve(fromProcessName: "opencode") == .openCode)
        #expect(AgentType.resolve(fromProcessName: "kilo") == .kiloCode)
        #expect(AgentType.resolve(fromProcessName: "kilocode") == .kiloCode)
        #expect(
            AgentPresentationCatalog.stableIdentifier(
                forExecutableAlias: "opencode"
            ) == "openCode"
        )
        #expect(
            FirstPartyAgentCompatibilityCatalog.record(
                executableAlias: "opencode"
            )?.stableIdentifier == "openCode"
        )
        #expect(
            FirstPartyAgentCompatibilityCatalog.record(
                executableAlias: "kilo"
            )?.stableIdentifier == "kiloCode"
        )
        #expect(
            FirstPartyAgentCompatibilityCatalog.record(
                executableAlias: "kilocode"
            )?.stableIdentifier == "kiloCode"
        )
    }
}
