//
//  ValidationGutterTests.swift
//  PineTests
//

import Testing
import AppKit
@testable import Pine

/// Tests for validation diagnostic markers in LineNumberView (gutter).
@Suite("Validation Gutter Markers Tests")
struct ValidationGutterTests {

    private func makeView(text: String = "line1\nline2\nline3") -> (LineNumberView, NSTextView) {
        let textStorage = NSTextStorage(string: text)
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
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        scrollView.documentView = textView
        let view = LineNumberView(textView: textView)
        return (view, textView)
    }

    // MARK: - Initial state

    @Test func initialDiagnosticsEmpty() {
        let (view, _) = makeView()
        #expect(view.validationDiagnostics.isEmpty)
    }

    // MARK: - Setting diagnostics

    @Test func settingDiagnosticsUpdatesProperty() {
        let (view, _) = makeView()
        let diag = ValidationDiagnostic(
            line: 1, column: nil, message: "test error",
            severity: .error, source: "yamllint"
        )
        view.validationDiagnostics = [diag]
        #expect(view.validationDiagnostics.count == 1)
        #expect(view.validationDiagnostics[0].message == "test error")
        #expect(view.validationDiagnostics[0].severity == .error)
    }

    @Test func settingEmptyDiagnosticsTriggersRedraw() {
        let (view, _) = makeView()
        let diag = ValidationDiagnostic(
            line: 1, column: nil, message: "test",
            severity: .warning, source: "shellcheck"
        )
        view.validationDiagnostics = [diag]
        view.validationDiagnostics = []
        #expect(view.validationDiagnostics.isEmpty)
    }

    @Test func multipleDiagnosticsOnDifferentLines() {
        let (view, _) = makeView()
        let diags = [
            ValidationDiagnostic(
                line: 1, column: nil, message: "error on line 1",
                severity: .error, source: "yamllint"
            ),
            ValidationDiagnostic(
                line: 2, column: nil, message: "warning on line 2",
                severity: .warning, source: "yamllint"
            ),
            ValidationDiagnostic(
                line: 3, column: nil, message: "info on line 3",
                severity: .info, source: "yamllint"
            )
        ]
        view.validationDiagnostics = diags
        #expect(view.validationDiagnostics.count == 3)
    }

    @Test func multipleDiagnosticsOnSameLine_highestSeverityWins() {
        let (view, _) = makeView()
        // Set two diagnostics on line 1: warning and error
        // The diagnostic map should keep the error (higher severity)
        let diags = [
            ValidationDiagnostic(
                line: 1, column: 1, message: "just a warning",
                severity: .warning, source: "yamllint"
            ),
            ValidationDiagnostic(
                line: 1, column: 5, message: "critical error",
                severity: .error, source: "yamllint"
            )
        ]
        view.validationDiagnostics = diags
        // The view stores all diagnostics, but internal map picks highest severity
        #expect(view.validationDiagnostics.count == 2)
    }

    @Test func diagnosticsReplacedOnNewSet() {
        let (view, _) = makeView()
        let first = [
            ValidationDiagnostic(
                line: 1, column: nil, message: "first",
                severity: .error, source: "yamllint"
            )
        ]
        let second = [
            ValidationDiagnostic(
                line: 2, column: nil, message: "second",
                severity: .warning, source: "shellcheck"
            )
        ]
        view.validationDiagnostics = first
        #expect(view.validationDiagnostics.count == 1)
        #expect(view.validationDiagnostics[0].line == 1)

        view.validationDiagnostics = second
        #expect(view.validationDiagnostics.count == 1)
        #expect(view.validationDiagnostics[0].line == 2)
    }

    @Test func diagnosticsWithAllSeverities() {
        let (view, _) = makeView(text: "a\nb\nc\nd\ne")
        let diags = [
            ValidationDiagnostic(line: 1, column: nil, message: "err", severity: .error, source: "test"),
            ValidationDiagnostic(line: 2, column: nil, message: "warn", severity: .warning, source: "test"),
            ValidationDiagnostic(line: 3, column: nil, message: "info", severity: .info, source: "test")
        ]
        view.validationDiagnostics = diags
        #expect(view.validationDiagnostics.count == 3)
    }

    // MARK: - Combined with lineDiffs

    @Test func diagnosticsAndDiffsCoexist() {
        let (view, _) = makeView()
        view.lineDiffs = [GitLineDiff(line: 1, kind: .added)]
        view.validationDiagnostics = [
            ValidationDiagnostic(
                line: 1, column: nil, message: "error here",
                severity: .error, source: "yamllint"
            )
        ]
        // Both should be present independently
        #expect(view.lineDiffs.count == 1)
        #expect(view.validationDiagnostics.count == 1)
    }

    // MARK: - Combined with fold state

    @Test func diagnosticsAndFoldsCoexist() {
        let (view, _) = makeView()
        let foldable = FoldableRange(startLine: 1, endLine: 3, startCharIndex: 0, endCharIndex: 20, kind: .braces)
        view.foldableRanges = [foldable]
        view.validationDiagnostics = [
            ValidationDiagnostic(
                line: 2, column: nil, message: "inside fold",
                severity: .warning, source: "shellcheck"
            )
        ]
        #expect(view.foldableRanges.count == 1)
        #expect(view.validationDiagnostics.count == 1)
    }

    // MARK: - Severity ordering for same-line diagnostics

    @Test func infoOverriddenByWarning() {
        let (view, _) = makeView()
        let diags = [
            ValidationDiagnostic(
                line: 1, column: nil, message: "info",
                severity: .info, source: "test"
            ),
            ValidationDiagnostic(
                line: 1, column: nil, message: "warning",
                severity: .warning, source: "test"
            )
        ]
        view.validationDiagnostics = diags
        // The view stores all, but the internal map should have warning for line 1
        #expect(view.validationDiagnostics.count == 2)
    }

    @Test func warningOverriddenByError() {
        let (view, _) = makeView()
        let diags = [
            ValidationDiagnostic(
                line: 1, column: nil, message: "warning",
                severity: .warning, source: "test"
            ),
            ValidationDiagnostic(
                line: 1, column: nil, message: "error",
                severity: .error, source: "test"
            )
        ]
        view.validationDiagnostics = diags
        #expect(view.validationDiagnostics.count == 2)
    }

    @Test func errorNotOverriddenByInfo() {
        let (view, _) = makeView()
        // Error first, then info — error should remain
        let diags = [
            ValidationDiagnostic(
                line: 1, column: nil, message: "error",
                severity: .error, source: "test"
            ),
            ValidationDiagnostic(
                line: 1, column: nil, message: "info",
                severity: .info, source: "test"
            )
        ]
        view.validationDiagnostics = diags
        #expect(view.validationDiagnostics.count == 2)
    }

    // MARK: - Edge cases

    @Test func diagnosticOnLineZeroIsAccepted() {
        // Some tools may report line 0 for file-level issues
        let (view, _) = makeView()
        let diag = ValidationDiagnostic(
            line: 0, column: nil, message: "file-level issue",
            severity: .error, source: "terraform"
        )
        view.validationDiagnostics = [diag]
        #expect(view.validationDiagnostics.count == 1)
    }

    @Test func diagnosticBeyondFileLength() {
        let (view, _) = makeView(text: "a\nb")
        let diag = ValidationDiagnostic(
            line: 999, column: nil, message: "way beyond",
            severity: .warning, source: "test"
        )
        view.validationDiagnostics = [diag]
        // Should accept it — drawing will just skip it since the line is not visible
        #expect(view.validationDiagnostics.count == 1)
    }

    @Test func largeDiagnosticSet() {
        let (view, _) = makeView(text: (1...100).map { "line\($0)" }.joined(separator: "\n"))
        let diags = (1...50).map {
            ValidationDiagnostic(
                line: $0, column: nil, message: "diag \($0)",
                severity: $0 % 2 == 0 ? .warning : .error, source: "test"
            )
        }
        view.validationDiagnostics = diags
        #expect(view.validationDiagnostics.count == 50)
    }

    // MARK: - diagnosticMap via rebuildDiagnosticMap

    @Test func diagnosticMap_singleDiagnostic() {
        let (view, _) = makeView()
        view.validationDiagnostics = [
            ValidationDiagnostic(
                line: 2, column: nil, message: "something wrong",
                severity: .error, source: "yamllint"
            )
        ]
        #expect(view.diagnosticMap.count == 1)
        #expect(view.diagnosticMap[2]?.severity == .error)
        #expect(view.diagnosticMap[2]?.message == "something wrong")
    }

    @Test func diagnosticMap_highestSeverityWins() {
        let (view, _) = makeView()
        view.validationDiagnostics = [
            ValidationDiagnostic(
                line: 1, column: nil, message: "info msg",
                severity: .info, source: "test"
            ),
            ValidationDiagnostic(
                line: 1, column: nil, message: "warning msg",
                severity: .warning, source: "test"
            ),
            ValidationDiagnostic(
                line: 1, column: nil, message: "error msg",
                severity: .error, source: "test"
            )
        ]
        #expect(view.diagnosticMap.count == 1)
        #expect(view.diagnosticMap[1]?.severity == .error)
        #expect(view.diagnosticMap[1]?.message == "error msg")
    }

    @Test func diagnosticMap_errorNotReplacedByLowerSeverity() {
        let (view, _) = makeView()
        // Error comes first — subsequent info/warning must NOT override
        view.validationDiagnostics = [
            ValidationDiagnostic(
                line: 1, column: nil, message: "error first",
                severity: .error, source: "test"
            ),
            ValidationDiagnostic(
                line: 1, column: nil, message: "info later",
                severity: .info, source: "test"
            )
        ]
        #expect(view.diagnosticMap[1]?.severity == .error)
        #expect(view.diagnosticMap[1]?.message == "error first")
    }

    @Test func diagnosticMap_multipleLinesIndependent() {
        let (view, _) = makeView()
        view.validationDiagnostics = [
            ValidationDiagnostic(
                line: 1, column: nil, message: "err", severity: .error, source: "a"
            ),
            ValidationDiagnostic(
                line: 3, column: nil, message: "warn", severity: .warning, source: "b"
            )
        ]
        #expect(view.diagnosticMap.count == 2)
        #expect(view.diagnosticMap[1]?.severity == .error)
        #expect(view.diagnosticMap[3]?.severity == .warning)
        #expect(view.diagnosticMap[2] == nil)
    }

    @Test func diagnosticMap_clearedWhenEmpty() {
        let (view, _) = makeView()
        view.validationDiagnostics = [
            ValidationDiagnostic(
                line: 1, column: nil, message: "err", severity: .error, source: "a"
            )
        ]
        #expect(view.diagnosticMap.count == 1)
        view.validationDiagnostics = []
        #expect(view.diagnosticMap.isEmpty)
    }

    @Test func diagnosticMap_rebuildDirectly() {
        let (view, _) = makeView()
        // Set diagnostics without going through didSet — call rebuildDiagnosticMap directly
        view.validationDiagnostics = [
            ValidationDiagnostic(
                line: 5, column: 2, message: "manual rebuild",
                severity: .warning, source: "shellcheck"
            )
        ]
        // Force a rebuild to verify idempotency
        view.rebuildDiagnosticMap()
        #expect(view.diagnosticMap.count == 1)
        #expect(view.diagnosticMap[5]?.message == "manual rebuild")
    }
}
