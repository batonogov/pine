//
//  ProblemsPanelAccessibilityTests.swift
//  PineTests
//
//  The Problems panel announced a diagnostic's message without its severity
//  (#1533): the severity symbol carried no label, so VoiceOver read
//  "Unexpected token, line 3, shellcheck" and dropped that the row was an
//  error. The row is hosted directly because a `List` does not materialize
//  its cells in an offscreen window — and the assertions read the published
//  tree rather than the view code, because a modifier is a request, not a
//  guarantee.
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Pine

@Suite("Problems panel accessibility (#1533)", .serialized)
@MainActor
struct ProblemsPanelAccessibilityTests {

    private static let hostSize = NSSize(width: 480, height: 60)

    @Test("a diagnostic row announces its severity together with the message")
    func rowAnnouncesSeverity() throws {
        let hosted = AccessibilityTreeProbe.host(
            ProblemsDiagnosticRow(
                diagnostic: makeDiagnostic(severity: .error, message: "Unexpected token"),
                isSelected: false,
                action: {}
            ),
            size: Self.hostSize
        )
        defer { hosted.tearDown() }

        let announced = try #require(
            AccessibilityTreeProbe.labels(under: hosted.root)
                .first { $0.contains("Unexpected token") },
            "no element announces the diagnostic message — the row never reached the tree"
        )
        #expect(
            announced.contains(Strings.diagnosticSeverityError),
            "the row announces \"\(announced)\" without its severity"
        )
    }

    @Test("each severity announces its own name, not a neighbour's")
    func severitiesAreDistinct() throws {
        let hosted = AccessibilityTreeProbe.host(
            VStack(spacing: 0) {
                ProblemsDiagnosticRow(
                    diagnostic: makeDiagnostic(
                        severity: .warning, message: "Trailing whitespace"
                    ),
                    isSelected: false,
                    action: {}
                )
                ProblemsDiagnosticRow(
                    diagnostic: makeDiagnostic(
                        severity: .info, message: "Consider adding a comment"
                    ),
                    isSelected: false,
                    action: {}
                )
            },
            size: NSSize(width: 480, height: 120)
        )
        defer { hosted.tearDown() }

        let labels = AccessibilityTreeProbe.labels(under: hosted.root)
        let warning = try #require(
            labels.first { $0.contains("Trailing whitespace") }
        )
        let info = try #require(
            labels.first { $0.contains("Consider adding a comment") }
        )
        #expect(warning.contains(Strings.diagnosticSeverityWarning))
        #expect(!warning.contains(Strings.diagnosticSeverityInfo))
        #expect(info.contains(Strings.diagnosticSeverityInfo))
        #expect(!info.contains(Strings.diagnosticSeverityWarning))
    }

    private func makeDiagnostic(
        severity: ValidationSeverity,
        message: String
    ) -> ValidationDiagnostic {
        ValidationDiagnostic(
            line: 3,
            column: 7,
            message: message,
            severity: severity,
            source: "shellcheck"
        )
    }
}
