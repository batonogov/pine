//
//  PerformanceTestHelpers.swift
//  PinePerformanceTests
//

import AppKit
import XCTest

// MARK: - Shared Code Generation

enum PerformanceTestHelpers {

    /// Generates a realistic Swift-like source file with the given number of lines.
    /// Used across multiple performance test files to avoid code duplication.
    static func generateSwiftCode(lines: Int, classPrefix: String = "Perf") -> String {
        var result: [String] = ["import Foundation", "import AppKit", ""]
        var classIdx = 0
        var lineCount = 3
        while lineCount < lines {
            result.append("class \(classPrefix)\(classIdx): NSObject {")
            result.append("    var value: Int = \(classIdx)")
            for method in 0..<5 {
                guard lineCount + 8 < lines else { break }
                result.append("    func compute\(method)(input: Int) -> String {")
                result.append("        let result = input * \(method + 1)")
                result.append("        if result > 100 {")
                result.append("            return \"large: \\(result)\"")
                result.append("        }")
                result.append("        return \"small: \\(result)\"")
                result.append("    }")
                lineCount += 7
            }
            result.append("}")
            result.append("")
            lineCount += 4
            classIdx += 1
        }
        return result.joined(separator: "\n")
    }
}

// MARK: - Text System Creation

enum TextSystemCreationError: Error {
    case missingTextStorage
    case missingLayoutManager
}

extension XCTestCase {

    /// Creates a fully configured text system from the given text content.
    /// Throws instead of silently returning empty objects.
    func createTextSystem(
        text: String
    ) throws -> (NSTextView, NSTextStorage, NSLayoutManager) {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        textView.textContainer?.size = NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true

        guard let textStorage = textView.textStorage else {
            XCTFail("NSTextView.textStorage is nil — text system not configured")
            throw TextSystemCreationError.missingTextStorage
        }
        guard let layoutManager = textView.layoutManager else {
            XCTFail("NSTextView.layoutManager is nil — text system not configured")
            throw TextSystemCreationError.missingLayoutManager
        }
        textStorage.setAttributedString(NSAttributedString(string: text))

        return (textView, textStorage, layoutManager)
    }
}
