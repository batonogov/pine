//
//  StructuralProviderPerformanceTests.swift
//  PinePerformanceTests
//
//  Large-snapshot and edit-cycle baselines for the structural symbol
//  fallback introduced by issue #1008.
//

import XCTest

@testable import Pine

final class StructuralProviderPerformanceTests: XCTestCase {
    func testLargeRegexSymbolSnapshot() {
        let text = PerformanceTestHelpers.generateSwiftCode(
            lines: 5_000,
            classPrefix: "Structural"
        )

        measure(metrics: [XCTClockMetric()]) {
            _ = SymbolParser.parse(
                content: text,
                fileExtension: "swift"
            )
        }
    }

    func testRegexSymbolSnapshotAfterIncrementalEdit() {
        let original = PerformanceTestHelpers.generateSwiftCode(
            lines: 2_000,
            classPrefix: "Edited"
        )
        let edited = original
            + "\nfunc newlyAddedDeclaration() {}\n"

        measure(metrics: [XCTClockMetric()]) {
            _ = SymbolParser.parse(
                content: edited,
                fileExtension: "swift"
            )
        }
    }
}
