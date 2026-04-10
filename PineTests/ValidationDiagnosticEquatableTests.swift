//
//  ValidationDiagnosticEquatableTests.swift
//  PineTests
//
//  Guards the manual `Equatable` conformance on `ValidationDiagnostic`:
//  two diagnostics with identical user-visible fields must compare equal
//  even though their synthesized `id` UUIDs differ. This is load-bearing
//  for `LineNumberView.validationDiagnostics.didSet`, which uses `!=` to
//  decide whether to dismiss the open diagnostic popover (#781).
//

import Testing
@testable import Pine

@Suite("ValidationDiagnostic Equatable")
struct ValidationDiagnosticEquatableTests {

    private func make(
        line: Int = 1,
        column: Int? = nil,
        message: String = "x",
        severity: ValidationSeverity = .error,
        source: String = "s"
    ) -> ValidationDiagnostic {
        ValidationDiagnostic(
            line: line, column: column, message: message, severity: severity, source: source
        )
    }

    @Test func equalInstances_haveDifferentIdsButCompareEqual() {
        let left = make()
        let right = make()
        #expect(left.id != right.id, "UUIDs must be unique per instance")
        #expect(left == right, "Equatable must ignore id")
    }

    @Test func emptyArraysAreEqual() {
        let left: [ValidationDiagnostic] = []
        let right: [ValidationDiagnostic] = []
        #expect(left == right)
    }

    @Test func identicalArraysAreEqual() {
        let left = [make(line: 1, message: "a"), make(line: 3, message: "b", severity: .warning)]
        let right = [make(line: 1, message: "a"), make(line: 3, message: "b", severity: .warning)]
        #expect(left == right)
    }

    @Test func messageDifferenceBreaksEquality() {
        #expect(make(message: "a") != make(message: "b"))
    }

    @Test func severityDifferenceBreaksEquality() {
        #expect(make(severity: .error) != make(severity: .warning))
    }

    @Test func lineDifferenceBreaksEquality() {
        #expect(make(line: 1) != make(line: 2))
    }

    @Test func columnDifferenceBreaksEquality() {
        #expect(make(column: 3) != make(column: 4))
    }

    @Test func sourceDifferenceBreaksEquality() {
        #expect(make(source: "a") != make(source: "b"))
    }

    @Test func countDifferenceBreaksArrayEquality() {
        let one = [make()]
        let empty: [ValidationDiagnostic] = []
        #expect(one != empty)
    }
}
