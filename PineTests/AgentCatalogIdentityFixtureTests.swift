import Foundation
import Testing
@testable import Pine

@MainActor
struct AgentCatalogIdentityFixtureTests {
    private struct Fixture: Decodable {
        let schemaVersion: UInt16
        let fixtureVersion: String
        let sanitization: String
        let cases: [IdentityCase]
    }

    private struct IdentityCase: Decodable {
        let name: String
        let command: String
        let expectedExecutable: String
        let expectedStableIdentifier: String?
    }

    @Test("shared identity fixture covers every retained alias and helper lookalike")
    func fixtureCoversRetainedCatalog() throws {
        let fixture = try loadFixture()
        let records = FirstPartyAgentCompatibilityCatalog.records
        #expect(fixture.schemaVersion == FirstPartyAgentCompatibilityCatalog.schemaVersion)
        #expect(fixture.fixtureVersion == "2026-11-14")
        #expect(fixture.sanitization.contains("never executed"))
        #expect(Set(fixture.cases.map(\.name)).count == fixture.cases.count)
        #expect(Set(fixture.cases.compactMap(\.expectedStableIdentifier)) == Set(records.map(\.stableIdentifier)))
        for record in records {
            for alias in record.executableAliases {
                #expect(fixture.cases.contains {
                    $0.command == alias && $0.expectedStableIdentifier == record.stableIdentifier
                })
                #expect(fixture.cases.contains {
                    $0.command == "\(alias)-helper" && $0.expectedStableIdentifier == nil
                })
            }
        }
    }

    @Test("shared process cases preserve exact aliases and generic collision boundaries")
    func classificationsMatchFixture() throws {
        for item in try loadFixture().cases {
            let executable = AgentDetector.extractExecutableName(from: item.command)
            #expect(executable == item.expectedExecutable, "\(item.name)")
            #expect(
                AgentPresentationCatalog.stableIdentifier(forExecutableAlias: executable.lowercased())
                    == item.expectedStableIdentifier,
                "\(item.name)"
            )
            let resolved = try #require(AgentType.resolve(fromProcessName: executable))
            if let expected = item.expectedStableIdentifier {
                #expect(resolved.stableIdentifier == expected, "\(item.name)")
            } else {
                #expect(resolved == .generic(name: executable), "\(item.name)")
            }
        }
    }

    @Test("shared lookalikes never create detected sessions while exact identities stay distinct")
    func snapshotsPreserveIdentityBoundaries() throws {
        let fixture = try loadFixture()
        let detector = AgentDetector()
        let processes = fixture.cases.enumerated().map { index, item in
            DetectedProcess(pid: Int32(10_000 + index), command: item.command)
        }
        detector.processSnapshotDidUpdate(processes)
        #expect(detector.detectedSessions.count == fixture.cases.filter {
            $0.expectedStableIdentifier != nil
        }.count)
        for (index, item) in fixture.cases.enumerated() {
            let session = detector.session(forPID: Int32(10_000 + index))
            if let expected = item.expectedStableIdentifier {
                #expect(session?.agentType.stableIdentifier == expected, "\(item.name)")
            } else {
                #expect(session == nil, "\(item.name)")
            }
        }
    }

    private func loadFixture() throws -> Fixture {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/AgentAdapters/identity-boundaries-v1.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL))
    }
}
