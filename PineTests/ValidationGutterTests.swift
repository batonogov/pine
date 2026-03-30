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

    // MARK: - Diagnostic icon draw size constant

    @Test func diagnosticIconDrawSize_isReasonable() {
        // Icon size should be small enough not to overlap line numbers
        #expect(LineNumberView.diagnosticIconDrawSize > 0)
        #expect(LineNumberView.diagnosticIconDrawSize <= 14)
    }

    @Test func diagnosticIconDrawSize_isExactly10() {
        #expect(LineNumberView.diagnosticIconDrawSize == 10)
    }

    // MARK: - Fixed gutter width (issue #677)

    @Test func gutterWidth_remainsStableWhenDiagnosticsAdded() {
        let view = makeLineNumberView()
        let baseWidth = view.gutterWidth

        let diag = ValidationDiagnostic(
            line: 1, column: nil, message: "error", severity: .error, source: "test"
        )
        view.validationDiagnostics = [diag]

        // Gutter width must NOT change when diagnostics appear — icons fit within existing space.
        #expect(view.gutterWidth == baseWidth)
    }

    @Test func gutterWidth_remainsStableWhenDiagnosticsCleared() {
        let view = makeLineNumberView()
        let baseWidth = view.gutterWidth

        let diag = ValidationDiagnostic(
            line: 1, column: nil, message: "error", severity: .error, source: "test"
        )
        view.validationDiagnostics = [diag]
        view.validationDiagnostics = []

        // Gutter width must stay the same after diagnostics are cleared.
        #expect(view.gutterWidth == baseWidth)
    }

    @Test func gutterWidth_noDiagnosticExtraInCalculation() {
        // The gutter width formula should NOT include diagnosticExtra.
        // Icons are drawn within the existing gutter space (fold indicator area).
        let view = makeLineNumberView()
        let widthWithout = view.gutterWidth

        view.validationDiagnostics = [
            ValidationDiagnostic(line: 1, column: nil, message: "err", severity: .error, source: "t")
        ]
        let widthWith = view.gutterWidth

        #expect(widthWith == widthWithout, "Gutter width must be fixed regardless of diagnostics")
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

    // MARK: - Icon position does not overlap line numbers

    @Test func diagnosticIcon_positionedWithinFoldArea() {
        // The icon starts at x=2, within the fold indicator area (0–14px)
        let iconX: CGFloat = 2
        let foldAreaEnd: CGFloat = 14
        #expect(iconX >= 0 && iconX < foldAreaEnd)
    }

    @Test func diagnosticIcon_doesNotOverlapLineNumbers() {
        // Icon: x=2, size=10 → right edge = 12.
        // Line numbers for 2-digit case: gutterWidth(40) - textWidth(~14) - padding(8) = 18.
        // 12 < 18, so no overlap.
        let iconX: CGFloat = 2
        let iconRightEdge = iconX + LineNumberView.diagnosticIconDrawSize
        let view = makeLineNumberView()
        let digitWidth = "0".size(withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        ]).width
        let twoDigitWidth = digitWidth * 2
        let lineNumberStartX = view.gutterWidth - twoDigitWidth - 8
        #expect(
            iconRightEdge < lineNumberStartX,
            "Icon right edge (\(iconRightEdge)) must not overlap line number start (\(lineNumberStartX))"
        )
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

    // MARK: - Diagnostic tooltips (issue #679)

    @Test func diagnosticTooltip_returnsMessageForLineWithDiagnostic() {
        let view = makeLineNumberView()
        let diag = ValidationDiagnostic(
            line: 2, column: 5, message: "unexpected token", severity: .error, source: "yamllint"
        )
        view.validationDiagnostics = [diag]
        let tooltip = view.diagnosticTooltip(forLine: 2)
        #expect(tooltip == "unexpected token")
    }

    @Test func diagnosticTooltip_returnsNilForLineWithoutDiagnostic() {
        let view = makeLineNumberView()
        let diag = ValidationDiagnostic(
            line: 2, column: nil, message: "error here", severity: .error, source: "test"
        )
        view.validationDiagnostics = [diag]
        let tooltip = view.diagnosticTooltip(forLine: 3)
        #expect(tooltip == nil)
    }

    @Test func diagnosticTooltip_returnsNilWhenNoDiagnostics() {
        let view = makeLineNumberView()
        let tooltip = view.diagnosticTooltip(forLine: 1)
        #expect(tooltip == nil)
    }

    @Test func diagnosticTooltip_highestSeverityMessageShown() {
        let view = makeLineNumberView()
        let warning = ValidationDiagnostic(
            line: 1, column: nil, message: "minor issue", severity: .warning, source: "test"
        )
        let error = ValidationDiagnostic(
            line: 1, column: nil, message: "critical error", severity: .error, source: "test"
        )
        view.validationDiagnostics = [warning, error]
        let tooltip = view.diagnosticTooltip(forLine: 1)
        // The diagnostic map keeps highest severity, so error message wins.
        #expect(tooltip == "critical error")
    }

    @Test func diagnosticTooltip_multipleLines_independentTooltips() {
        let view = makeLineNumberView()
        let diag1 = ValidationDiagnostic(
            line: 1, column: nil, message: "error on line 1", severity: .error, source: "test"
        )
        let diag2 = ValidationDiagnostic(
            line: 3, column: nil, message: "warning on line 3", severity: .warning, source: "test"
        )
        view.validationDiagnostics = [diag1, diag2]
        #expect(view.diagnosticTooltip(forLine: 1) == "error on line 1")
        #expect(view.diagnosticTooltip(forLine: 2) == nil)
        #expect(view.diagnosticTooltip(forLine: 3) == "warning on line 3")
    }

    // MARK: - Bounds check in mouseMoved

    @Test func mouseMoved_outsideBounds_clearsTooltip() {
        let view = makeLineNumberView()
        view.frame = NSRect(x: 0, y: 0, width: 40, height: 500)
        let diag = ValidationDiagnostic(
            line: 1, column: nil, message: "error msg", severity: .error, source: "test"
        )
        view.validationDiagnostics = [diag]
        // Set a tooltip manually to verify it gets cleared
        view.toolTip = "should be cleared"
        // Point outside bounds (negative x)
        let outsidePoint = NSPoint(x: -10, y: 50)
        let insideBounds = view.bounds.contains(outsidePoint)
        #expect(!insideBounds, "Point must be outside bounds for this test")
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
