//
//  AgentHistoryUndoReviewSnapshotTests.swift
//  PineTests
//

import AppKit
import SwiftUI
import Testing

@testable import Pine

@Suite("Agent History Undo Review snapshots")
@MainActor
struct AgentHistoryUndoReviewSnapshotTests {
    private let size = NSSize(width: 680, height: 540)
    private let locale = Locale(identifier: "en")

    @Test("Ready review renders binary and omitted operations")
    func readyLight() throws {
        try assertSnapshot(
            of: review(
                result: .available(
                    AgentHistoryUndoReviewTestFixtures.mixedContentModel()
                ),
                phase: .ready
            ),
            size: size,
            appearance: .light,
            named: "AgentHistoryUndoReview.ready-mixed.light",
            tolerance: 0.02
        )
    }

    @Test("A stale conflict renders fail-closed guidance")
    func staleDark() throws {
        try assertSnapshot(
            of: review(
                result: .unavailable(
                    .currentContentDiverged(
                        path: "Sources/HumanEdited.swift"
                    )
                ),
                phase: .blocked(
                    .currentContentDiverged(
                        path: "Sources/HumanEdited.swift"
                    )
                )
            ),
            size: size,
            appearance: .dark,
            named: "AgentHistoryUndoReview.stale-conflict.dark",
            tolerance: 0.02
        )
    }

    @Test("Applying review visibly locks destructive and dismiss actions")
    func applyingDark() throws {
        try assertSnapshot(
            of: review(
                result: .available(
                    AgentHistoryUndoReviewTestFixtures.mixedContentModel()
                ),
                phase: .applying,
                revalidation: .available(
                    AgentHistoryUndoReviewTestFixtures.mixedContentModel()
                )
            ),
            size: size,
            appearance: .dark,
            named: "AgentHistoryUndoReview.applying-locked.dark",
            tolerance: 0.02
        )
    }

    private func review(
        result: AgentHistoryUndoPreviewResult,
        phase: AgentHistoryUndoReviewActionGate.Phase,
        revalidation: AgentHistoryUndoPreviewResult? = nil
    ) -> some View {
        AgentHistoryUndoReviewView(
            previewResult: result,
            phase: phase,
            revalidation: revalidation
        )
        .environment(\.locale, locale)
        .frame(width: size.width, height: size.height)
    }
}
