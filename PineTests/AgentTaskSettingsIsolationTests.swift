//
//  AgentTaskSettingsIsolationTests.swift
//  PineTests
//
//  Settings and service isolation for concurrent ADE tasks (#1728 audit
//  additions): recorded scopes, two tasks plus an independent reviewer with
//  differing settings (including the same canonical directory),
//  serialize-or-unsupported decisions, immutable per-launch snapshots, and
//  descendant teardown that preserves shared services and unknown ownership.
//

import Foundation
import Testing
@testable import Pine

@Suite("ADE task settings isolation (#1728)")
struct AgentTaskSettingsIsolationTests {
    private func task(_ seed: Int) -> UUID {
        let suffix = String(format: "%012llX", UInt64(seed + 1))
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)") ?? UUID()
    }

    private func launch(
        _ seed: Int,
        generation: UInt64 = 1,
        values: [String: String]
    ) -> AgentTaskLaunchSettings {
        AgentTaskLaunchSettings(
            taskID: task(seed),
            runID: UUID(),
            launchGeneration: generation,
            values: values
        )
    }

    @Test func twoTasksPlusReviewerWithDifferingIsolatedSettingsRunConcurrently() {
        let taskA = launch(1, values: [
            "terminalEnvironment": "A",
            "derivedDataPath": "/dd/A",
            "workingDirectory": "/repo/wt-a",
        ])
        let taskB = launch(2, values: [
            "terminalEnvironment": "B",
            "derivedDataPath": "/dd/B",
            "workingDirectory": "/repo/wt-b",
        ])
        let reviewer = launch(3, values: [
            "terminalEnvironment": "R",
            "derivedDataPath": "/dd/R",
            "workingDirectory": "/repo/wt-b",
        ])
        #expect(
            AgentTaskSettingsIsolation.compatibility(of: taskA, and: taskB)
                == .concurrent
        )
        #expect(
            AgentTaskSettingsIsolation.compatibility(of: taskB, and: reviewer)
                == .concurrent
        )
    }

    @Test func sameCanonicalDirectoryIsSupportedWhenValuesAreIsolatedOrEqual() {
        let taskA = launch(4, values: [
            "workingDirectory": "/repo/shared",
            "derivedDataPath": "/dd/A",
        ])
        let taskB = launch(5, values: [
            "workingDirectory": "/repo/shared",
            "derivedDataPath": "/dd/B",
        ])
        #expect(
            AgentTaskSettingsIsolation.compatibility(of: taskA, and: taskB)
                == .concurrent
        )
    }

    @Test func conflictingNonIsolatedSettingSerializesWhenSerializable() {
        let taskA = launch(6, values: ["approvalPolicy": "strict"])
        let taskB = launch(7, values: ["approvalPolicy": "permissive"])
        #expect(
            AgentTaskSettingsIsolation.compatibility(of: taskA, and: taskB)
                == .serialized
        )
        // Equal values on a shared non-isolated setting are not a conflict.
        let reviewer = launch(8, values: ["approvalPolicy": "strict"])
        #expect(
            AgentTaskSettingsIsolation.compatibility(of: taskA, and: reviewer)
                == .concurrent
        )
    }

    @Test func conflictingNonIsolatedSettingExposesUnsupportedCombination() {
        let taskA = launch(9, values: ["mcpServerDefinitions": "set-A"])
        let taskB = launch(10, values: ["mcpServerDefinitions": "set-B"])
        #expect(
            AgentTaskSettingsIsolation.compatibility(of: taskA, and: taskB)
                == .unsupported(conflicting: ["mcpServerDefinitions"])
        )
        // Credential and billing conflicts are concretely unsupported too.
        let c = launch(11, values: ["providerCredentials": "account-A"])
        let d = launch(12, values: ["providerCredentials": "account-B"])
        #expect(
            AgentTaskSettingsIsolation.compatibility(of: c, and: d)
                == .unsupported(conflicting: ["providerCredentials"])
        )
    }

    @Test func unknownSettingNamesFailClosed() {
        let taskA = launch(13, values: ["futureUnknownSetting": "A"])
        let taskB = launch(14, values: ["futureUnknownSetting": "B"])
        #expect(
            AgentTaskSettingsIsolation.compatibility(of: taskA, and: taskB)
                == .unsupported(conflicting: ["futureUnknownSetting"])
        )
    }

    @Test func launchSnapshotIsImmutableAcrossSettingsChanges() {
        let taskA = launch(15, values: ["approvalPolicy": "strict"])
        // A later settings change produces a NEW launch value; it never
        // rewrites the recorded snapshot of the running task.
        let changed = AgentTaskLaunchSettings(
            taskID: task(16),
            runID: UUID(),
            launchGeneration: 2,
            values: ["approvalPolicy": "permissive"]
        )
        #expect(taskA.values["approvalPolicy"] == "strict")
        #expect(taskA != changed)
        #expect(changed.values["approvalPolicy"] == "permissive")
        // Revalidation compares live values against the snapshot: a change
        // is a difference, fail closed.
        #expect(taskA.values != changed.values)
    }

    @Test func teardownCoversOwnedDescendantsOnlyAndUnknownStaysUnknown() {
        let a = task(17)
        let aRun = UUID()
        let b = task(18)
        let jobs: [UUID: AgentTaskChildJobOwnership] = [
            UUID(): .owned(taskID: a, runID: aRun, launchGeneration: 1),
            UUID(): .owned(taskID: a, runID: aRun, launchGeneration: 2),
            UUID(): .owned(taskID: a, runID: UUID(), launchGeneration: 1),
            UUID(): .owned(taskID: b, runID: aRun, launchGeneration: 1),
            UUID(): .unknown,
        ]
        let targets = AgentTaskDescendantTeardown.teardownTargets(
            jobs: jobs, taskID: a, runID: aRun, launchGeneration: 1
        )
        // Exactly the jobs owned by the torn-down task, attempt, AND launch
        // generation. The other generation's job, another run's job, the
        // unrelated task's job, and the unknown job are all preserved.
        #expect(targets.count == 1)
        let expected = jobs.first {
            if case .owned(let t, let r, let g) = $0.value {
                return t == a && r == aRun && g == 1
            }
            return false
        }
        #expect(targets.contains(expected?.key ?? UUID()))
        #expect(!targets.contains(jobs.first { $0.value == .unknown }?.key ?? UUID()))
    }

    @Test func launchSettingsShapeIsValidated() {
        #expect(AgentTaskLaunchSettings.isValid(values: [:]) == true)
        #expect(
            AgentTaskLaunchSettings.isValid(
                values: ["approvalPolicy": "strict", "workingDirectory": "/repo/wt-a"]
            ) == true
        )
        #expect(
            AgentTaskLaunchSettings.isValid(
                values: Dictionary(
                    uniqueKeysWithValues: (0..<AgentTaskLaunchSettings.maximumEntries + 1)
                        .map { ("key\($0)", "v") }
                )
            ) == false
        )
        #expect(
            AgentTaskLaunchSettings.isValid(
                values: [
                    String(repeating: "k", count: AgentTaskLaunchSettings.maximumKeyBytes + 1): "v"
                ]
            ) == false
        )
        #expect(
            AgentTaskLaunchSettings.isValid(
                values: [
                    "k": String(repeating: "v", count: AgentTaskLaunchSettings.maximumValueBytes + 1)
                ]
            ) == false
        )
        // Control characters are rejected in keys and values.
        #expect(AgentTaskLaunchSettings.isValid(values: ["bad\nkey": "v"]) == false)
        #expect(AgentTaskLaunchSettings.isValid(values: ["key": "bad\nvalue"]) == false)
        #expect(AgentTaskLaunchSettings.isValid(values: ["": "v"]) == false)
    }

    @Test func isolationTableRecordsScopesForEveryKnownMutableSetting() {
        // The audit entry: every recorded setting names its scope, and the
        // scopes claimed as isolated are exactly the per-launch ones.
        let table = AgentTaskSettingsIsolationTable.known
        #expect(!table.isEmpty)
        #expect(Set(table.map(\.name)).count == table.count)
        for definition in table {
            let isolated = definition.isolatedAcrossConcurrentLaunches
            let perLaunchScope =
                definition.scope == .session
                || definition.scope == .directory
                || definition.scope == .ownedProcess
            #expect(
                isolated == perLaunchScope,
                "\(definition.name) scope \(definition.scope) isolation disagrees"
            )
        }
        #expect(
            AgentTaskSettingsIsolationTable.definition(
                named: "providerCredentials"
            )?.scope == .account
        )
        #expect(
            AgentTaskSettingsIsolationTable.definition(
                named: "mcpServerDefinitions"
            )?.scope == .global
        )
    }
}
