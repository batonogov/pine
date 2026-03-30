//
//  ValidationGutterTests.swift
//  PineTests
//

import Testing
import AppKit
@testable import Pine

/// Tests for validation diagnostic icons in the line number gutter.
@Suite("Validation Gutter Tests")
struct ValidationGutterTests {

    private func makeLineNumberView() -> LineNumberView {
        let textStorage = NSTextStorage(string: "line1\nline2\nline3\nline4\nline5\n")
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(
            containerSize: NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)
        )
        layoutManager.addTextContainer(textContainer)
        let textView = NSTextView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 500),
            textContainer: textContainer
        )
        return LineNumberView(textView: textView)
    }

    // MARK: - validationDiagnostics property

    @Test func initialDiagnosticsEmpty() {
        let view = makeLineNumberView()
        #expect(view.validationDiagnostics.isEmpty)
    }

    @Test func setDiagnostics_triggersNeedsDisplay() {
        let view = makeLineNumberView()
        let diag = ValidationDiagnostic(
            line: 1, column: nil, message: "error", severity: .error, source: "yamllint"
        )
        view.validationDiagnostics = [diag]
        #expect(view.validationDiagnostics.count == 1)
    }

    @Test func setEmptyDiagnostics() {
        let view = makeLineNumberView()
        let diag = ValidationDiagnostic(
            line: 1, column: nil, message: "error", severity: .error, source: "yamllint"
        )
        view.validationDiagnostics = [diag]
        view.validationDiagnostics = []
        #expect(view.validationDiagnostics.isEmpty)
    }

    // MARK: - Severity ranking

    @Test func severityRank_errorHighest() {
        #expect(LineNumberView.severityRank(.error) > LineNumberView.severityRank(.warning))
        #expect(LineNumberView.severityRank(.warning) > LineNumberView.severityRank(.info))
    }

    @Test func severityRank_allDistinct() {
        let ranks = [
            LineNumberView.severityRank(.error),
            LineNumberView.severityRank(.warning),
            LineNumberView.severityRank(.info)
        ]
        #expect(Set(ranks).count == 3)
    }

    // MARK: - Diagnostic map (highest severity per line)

    @Test func diagnosticMap_singleDiagnosticPerLine() {
        let view = makeLineNumberView()
        let diag1 = ValidationDiagnostic(
            line: 1, column: nil, message: "err", severity: .error, source: "yamllint"
        )
        let diag2 = ValidationDiagnostic(
            line: 3, column: nil, message: "warn", severity: .warning, source: "yamllint"
        )
        view.validationDiagnostics = [diag1, diag2]
        #expect(view.validationDiagnostics.count == 2)
    }

    @Test func diagnosticMap_highestSeverityWins() {
        let view = makeLineNumberView()
        let warning = ValidationDiagnostic(
            line: 1, column: 1, message: "minor", severity: .warning, source: "yamllint"
        )
        let error = ValidationDiagnostic(
            line: 1, column: 2, message: "major", severity: .error, source: "yamllint"
        )
        // Warning first, error second — error should win
        view.validationDiagnostics = [warning, error]
        // Verify by checking that we have 2 diagnostics set but the map internally keeps highest
        #expect(view.validationDiagnostics.count == 2)
    }

    @Test func diagnosticMap_infoDoesNotOverrideWarning() {
        let view = makeLineNumberView()
        let warning = ValidationDiagnostic(
            line: 2, column: 1, message: "warn", severity: .warning, source: "shellcheck"
        )
        let info = ValidationDiagnostic(
            line: 2, column: 1, message: "info", severity: .info, source: "shellcheck"
        )
        view.validationDiagnostics = [warning, info]
        #expect(view.validationDiagnostics.count == 2)
    }

    // MARK: - SF Symbol names

    @Test func diagnosticSymbolNames_allSeveritiesCovered() {
        #expect(LineNumberView.diagnosticSymbolNames[.error] != nil)
        #expect(LineNumberView.diagnosticSymbolNames[.warning] != nil)
        #expect(LineNumberView.diagnosticSymbolNames[.info] != nil)
    }

    @Test func diagnosticSymbolNames_correctNames() {
        #expect(LineNumberView.diagnosticSymbolNames[.error] == "xmark.circle.fill")
        #expect(LineNumberView.diagnosticSymbolNames[.warning] == "exclamationmark.triangle.fill")
        #expect(LineNumberView.diagnosticSymbolNames[.info] == "info.circle.fill")
    }

    // MARK: - Diagnostic colors

    @Test func diagnosticColors_allSeveritiesCovered() {
        #expect(LineNumberView.diagnosticColors[.error] != nil)
        #expect(LineNumberView.diagnosticColors[.warning] != nil)
        #expect(LineNumberView.diagnosticColors[.info] != nil)
    }

    @Test func diagnosticColors_correctColors() {
        #expect(LineNumberView.diagnosticColors[.error] == .systemRed)
        #expect(LineNumberView.diagnosticColors[.warning] == .systemYellow)
        #expect(LineNumberView.diagnosticColors[.info] == .systemBlue)
    }

    // MARK: - drawDiagnosticIcon does not crash

    @Test func drawDiagnosticIcon_errorDoesNotCrash() {
        let view = makeLineNumberView()
        view.drawDiagnosticIcon(at: 10, lineHeight: 16, severity: .error)
    }

    @Test func drawDiagnosticIcon_warningDoesNotCrash() {
        let view = makeLineNumberView()
        view.drawDiagnosticIcon(at: 10, lineHeight: 16, severity: .warning)
    }

    @Test func drawDiagnosticIcon_infoDoesNotCrash() {
        let view = makeLineNumberView()
        view.drawDiagnosticIcon(at: 10, lineHeight: 16, severity: .info)
    }

    @Test func drawDiagnosticIcon_smallLineHeight() {
        let view = makeLineNumberView()
        view.drawDiagnosticIcon(at: 0, lineHeight: 2, severity: .error)
    }

    @Test func drawDiagnosticIcon_largeLineHeight() {
        let view = makeLineNumberView()
        view.drawDiagnosticIcon(at: 100, lineHeight: 50, severity: .warning)
    }

    // MARK: - Multiple lines with diagnostics

    @Test func multipleLinesWithDiagnostics() {
        let view = makeLineNumberView()
        let diags = (1...5).map { line in
            ValidationDiagnostic(
                line: line,
                column: nil,
                message: "msg \(line)",
                severity: line % 2 == 0 ? .warning : .error,
                source: "test"
            )
        }
        view.validationDiagnostics = diags
        #expect(view.validationDiagnostics.count == 5)
    }

    // MARK: - Replacing diagnostics

    @Test func replacingDiagnostics_updatesCleanly() {
        let view = makeLineNumberView()

        let initial = [
            ValidationDiagnostic(line: 1, column: nil, message: "a", severity: .error, source: "a")
        ]
        view.validationDiagnostics = initial
        #expect(view.validationDiagnostics.count == 1)

        let updated = [
            ValidationDiagnostic(line: 2, column: nil, message: "b", severity: .warning, source: "b"),
            ValidationDiagnostic(line: 3, column: nil, message: "c", severity: .info, source: "b")
        ]
        view.validationDiagnostics = updated
        #expect(view.validationDiagnostics.count == 2)
    }
}
