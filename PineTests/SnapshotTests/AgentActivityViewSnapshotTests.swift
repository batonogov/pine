//
//  AgentActivityViewSnapshotTests.swift
//  PineTests
//
//  Visual snapshot tests for AgentActivityView (issue #1072) in light and
//  dark appearances. Consumes value-type AgentActivityRow projections, so no
//  live terminal or store is needed.
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Pine

@Suite("AgentActivityView Snapshots")
@MainActor
struct AgentActivityViewSnapshotTests {

    /// Matches the view's intrinsic frame (see AgentActivityView.body).
    private static let panelSize = NSSize(width: 420, height: 480)
    /// System colors + Circle anti-aliasing drift ~2–3% between Retina dev
    /// Macs and 1× CI runners (same rationale as AgentStatusBarItem).
    private static let tolerance = 0.03

    /// Fixed far-past timestamp so the relative-time label ("decades ago") is
    /// stable across runs and machines — a near-now timestamp would drift the
    /// rendered text between snapshot capture and comparison.
    private static let stableTimestamp = Date(timeIntervalSinceReferenceDate: 0)
    private static let sessionA = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)
    )
    private static let sessionB = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2)
    )

    /// macOS 26 and 27 rasterize the populated dark panel differently enough
    /// to exceed the shared 0.03 tolerance. Scope the OS-specific reference to
    /// this single snapshot; the other three references remain cross-version.
    private static var populatedDarkSnapshotName: String {
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26 {
            return "AgentActivityView.populated.dark.macos26"
        }
        return "AgentActivityView.populated.dark"
    }

    private func populatedRows() -> [AgentActivityRow] {
        [
            AgentAction(
                attribution: .inferred(
                    AgentActionCandidate(
                        sessionID: Self.sessionA,
                        agentType: .claudeCode
                    )
                ),
                kind: .fileWrite,
                status: .completed,
                timestamp: Self.stableTimestamp,
                fileURL: URL(fileURLWithPath: "/p/src/a.swift"),
                summary: Strings.agentActivityFileChanged("a.swift")
            ),
            AgentAction(
                attribution: .ambiguous(candidates: [
                    AgentActionCandidate(
                        sessionID: Self.sessionA,
                        agentType: .claudeCode
                    ),
                    AgentActionCandidate(
                        sessionID: Self.sessionB,
                        agentType: .codex
                    )
                ]),
                kind: .fileWrite,
                status: .completed,
                timestamp: Self.stableTimestamp,
                fileURL: URL(fileURLWithPath: "/p/src/shared.swift"),
                summary: Strings.agentActivityFileChanged("shared.swift")
            ),
            AgentAction(
                sessionID: Self.sessionB,
                agentType: .codex,
                kind: .command,
                status: .completed,
                timestamp: Self.stableTimestamp,
                summary: "ran npm test"
            ),
            AgentAction(
                sessionID: Self.sessionA,
                agentType: .claudeCode,
                kind: .toolCall,
                status: .failed,
                timestamp: Self.stableTimestamp,
                summary: "apply_patch failed"
            )
        ].map { AgentActivityRow($0) }
    }

    @Test("AgentActivityView renders populated panel in light appearance")
    func populatedLight() throws {
        let view = AgentActivityView(
            rows: populatedRows(),
            onSelectFile: { _ in },
            onClose: {},
            onGoToTerminal: { _ in false }
        )
        try assertSnapshot(
            of: view,
            size: Self.panelSize,
            appearance: .light,
            named: "AgentActivityView.populated.light",
            // Intentional Menu/ViewThatFits reflow exposes a slightly wider
            // AppKit/SwiftUI rasterization delta between macOS 26 and 27.
            tolerance: 0.04
        )
    }

    @Test("AgentActivityView renders populated panel in dark appearance")
    func populatedDark() throws {
        let rows = populatedRows()
        verifyPopulatedSemantics(rows)
        let view = AgentActivityView(
            rows: rows,
            onSelectFile: { _ in },
            onClose: {},
            onGoToTerminal: { _ in false }
        )
        if !SnapshotHarness.isHeadless {
            let bitmap = try SnapshotHarness.render(
                view: view,
                size: Self.panelSize,
                appearance: .dark
            )
            verifySnapshotIsNotBlank(bitmap)
        }
        verifyReferenceIsNotBlank(named: Self.populatedDarkSnapshotName)
        try assertSnapshot(
            of: view,
            size: Self.panelSize,
            appearance: .dark,
            named: Self.populatedDarkSnapshotName,
            tolerance: Self.tolerance
        )
    }

    @Test("AgentActivityView renders empty state in light appearance")
    func emptyLight() throws {
        let view = AgentActivityView(
            rows: [],
            onSelectFile: { _ in },
            onClose: {},
            onGoToTerminal: { _ in false }
        )
        try assertSnapshot(
            of: view,
            size: Self.panelSize,
            appearance: .light,
            named: "AgentActivityView.empty.light",
            tolerance: Self.tolerance
        )
    }

    @Test("AgentActivityView renders empty state in dark appearance")
    func emptyDark() throws {
        let view = AgentActivityView(
            rows: [],
            onSelectFile: { _ in },
            onClose: {},
            onGoToTerminal: { _ in false }
        )
        try assertSnapshot(
            of: view,
            size: Self.panelSize,
            appearance: .dark,
            named: "AgentActivityView.empty.dark",
            // Keep the macOS 26/27 material rasterization allowance scoped to
            // this empty dark reference.
            tolerance: 0.035
        )
    }

    @Test("Narrow long-localization layout remains renderable")
    func narrowLongLocalizationLayout() throws {
        guard !SnapshotHarness.isHeadless else { return }
        let size = NSSize(width: 300, height: 480)
        let view = AgentActivityView(
            rows: populatedRows(),
            panelWidth: size.width,
            onSelectFile: { _ in },
            onClose: {},
            onGoToTerminal: { _ in false }
        )
        .environment(\.locale, Locale(identifier: "de"))

        let bitmap = try SnapshotHarness.render(
            view: view,
            size: size,
            appearance: .light
        )
        #expect(bitmap.pixelsWide == 300)
        #expect(bitmap.pixelsHigh == 480)
        verifySnapshotIsNotBlank(bitmap)
    }

    @Test(
        "Detail evidence snapshots render verified, stale, terminated, and ambiguous states",
        arguments: [
            AgentLiveness.live as AgentLiveness?,
            AgentLiveness.stale as AgentLiveness?,
            AgentLiveness.terminated as AgentLiveness?,
            nil as AgentLiveness?
        ]
    )
    func detailEvidenceStates(liveness: AgentLiveness?) throws {
        guard !SnapshotHarness.isHeadless else { return }
        let action: AgentAction
        let target: AgentActivityTerminalTarget?
        if let liveness {
            let sessionID = UUID()
            action = AgentAction(
                attribution: .verified(
                    AgentActionCandidate(
                        sessionID: sessionID,
                        agentType: .codex
                    )
                ),
                kind: .command,
                status: .completed,
                timestamp: Self.stableTimestamp,
                summary: "Run tests"
            )
            target = AgentActivityTerminalTarget(
                paneID: PaneID(),
                tabID: UUID(),
                sessionID: sessionID,
                agentType: .codex,
                liveness: liveness,
                label: "Codex tests",
                workingDirectory: URL(fileURLWithPath: "/p")
            )
        } else {
            action = AgentAction(
                attribution: .ambiguous(candidates: [
                    AgentActionCandidate(
                        sessionID: Self.sessionA,
                        agentType: .claudeCode
                    ),
                    AgentActionCandidate(
                        sessionID: Self.sessionB,
                        agentType: .codex
                    )
                ]),
                kind: .toolCall,
                status: .failed,
                timestamp: Self.stableTimestamp,
                summary: "Apply patch"
            )
            target = nil
        }
        let view = AgentActivityDetailView(
            row: AgentActivityRow(action, terminalTarget: target),
            onSelectFile: { _ in },
            onGoToTerminal: { _ in false },
            onClose: {}
        )
        let bitmap = try SnapshotHarness.render(
            view: view,
            size: NSSize(width: 420, height: 460),
            appearance: .light
        )
        verifySnapshotIsNotBlank(bitmap)
    }

    private func verifyPopulatedSemantics(_ rows: [AgentActivityRow]) {
        let available = ActivityAttributionFilter.available(
            in: rows.map(\.attribution)
        )
        #expect(rows.count == 4)
        #expect(available == [.sessionLinked, .inferred, .ambiguous])
        #expect(rows.filter { $0.attribution.unambiguousCandidate == nil }.count == 1)
    }

    private func verifyReferenceIsNotBlank(named name: String) {
        let referenceURL = SnapshotHarness.referenceURL(
            for: name,
            testFile: #filePath
        )
        guard let referenceData = try? Data(contentsOf: referenceURL),
              let bitmap = NSBitmapImageRep(data: referenceData) else {
            Issue.record("Populated dark reference is missing or is not a valid PNG")
            return
        }
        verifySnapshotIsNotBlank(bitmap)
    }

    /// A platform-specific reference must not turn a blank render into a valid
    /// baseline. Require at least 1% of pixels to differ materially from the
    /// bottom-left background pixel before running the normal comparison.
    private func verifySnapshotIsNotBlank(_ bitmap: NSBitmapImageRep) {
        guard let data = bitmap.bitmapData,
              bitmap.samplesPerPixel >= 3,
              bitmap.pixelsWide > 0,
              bitmap.pixelsHigh > 0 else {
            Issue.record("Populated dark snapshot has no readable pixel buffer")
            return
        }

        let background = (data[0], data[1], data[2])
        var nonBackgroundPixels = 0
        for yPosition in 0..<bitmap.pixelsHigh {
            let rowStart = yPosition * bitmap.bytesPerRow
            for xPosition in 0..<bitmap.pixelsWide {
                let offset = rowStart + xPosition * bitmap.samplesPerPixel
                let differs = abs(Int(data[offset]) - Int(background.0)) > 8
                    || abs(Int(data[offset + 1]) - Int(background.1)) > 8
                    || abs(Int(data[offset + 2]) - Int(background.2)) > 8
                if differs {
                    nonBackgroundPixels += 1
                }
            }
        }

        let minimumContentPixels = bitmap.pixelsWide * bitmap.pixelsHigh / 100
        #expect(nonBackgroundPixels > minimumContentPixels)
    }
}
