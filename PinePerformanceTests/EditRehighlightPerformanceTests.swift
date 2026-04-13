//
//  EditRehighlightPerformanceTests.swift
//  PinePerformanceTests
//

import XCTest
import AppKit
@testable import Pine

@MainActor
final class EditRehighlightPerformanceTests: XCTestCase {

    private var highlighter: SyntaxHighlighter!

    override func setUp() {
        super.setUp()
        highlighter = SyntaxHighlighter.shared
        let grammar = Grammar(
            name: "EditPerfSwift",
            extensions: ["editperfswift"],
            rules: [
                GrammarRule(pattern: "//.*$", scope: "comment", options: ["anchorsMatchLines"]),
                GrammarRule(pattern: #"/\*[\s\S]*?\*/"#, scope: "comment", options: ["dotMatchesLineSeparators"]),
                GrammarRule(pattern: #""(?:[^"\\]|\\.)*""#, scope: "string"),
                GrammarRule(
                    pattern: #"\b(func|var|let|class|struct|enum|protocol|import|return"#
                        + #"|if|else|guard|switch|case|for|while|do|try|catch|throw|throws|async|await)\b"#,
                    scope: "keyword"
                ),
                GrammarRule(pattern: #"\b[A-Z][A-Za-z0-9_]*\b"#, scope: "type"),
                GrammarRule(pattern: #"\b\d+(\.\d+)?\b"#, scope: "number"),
            ]
        )
        highlighter.registerGrammar(grammar)
    }

    // MARK: - Helpers

    private func generateCode(lines: Int) -> String {
        var result: [String] = ["import Foundation", "import AppKit", ""]
        var classIdx = 0
        var lineCount = 3
        while lineCount < lines {
            result.append("class Editor\(classIdx): NSObject {")
            result.append("    var name: String = \"default\"")
            result.append("    let id: Int = \(classIdx)")
            for method in 0..<3 {
                guard lineCount + 8 < lines else { break }
                result.append("    func process\(method)(input: Int) -> String {")
                result.append("        let result = input * \(method + 1)")
                result.append("        if result > 50 {")
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

    // MARK: - Insert + Re-highlight

    /// Simulates typing a new line in the middle of a 2000-line file
    /// and re-highlighting the edited region.
    func testInsertLineAndRehighlight2000Lines() {
        let code = generateCode(lines: 2000)
        let textStorage = NSTextStorage(string: code)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        // Initial full highlight
        highlighter.highlight(textStorage: textStorage, language: "editperfswift", font: font)

        let insertText = "    let newVariable = \"inserted\" // new line\n"
        let midpoint = (code as NSString).length / 2

        measure {
            // Simulate insertion
            textStorage.replaceCharacters(
                in: NSRange(location: midpoint, length: 0),
                with: insertText
            )
            let editedRange = NSRange(location: midpoint, length: (insertText as NSString).length)

            // Re-highlight the edited region
            highlighter.highlightEdited(
                textStorage: textStorage,
                editedRange: editedRange,
                language: "editperfswift",
                font: font
            )

            // Undo the insertion to reset for next iteration
            textStorage.replaceCharacters(
                in: NSRange(location: midpoint, length: (insertText as NSString).length),
                with: ""
            )
        }
    }

    /// Simulates pasting a multi-line block (10 lines) and re-highlighting.
    func testPasteBlockAndRehighlight() {
        let code = generateCode(lines: 3000)
        let textStorage = NSTextStorage(string: code)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        highlighter.highlight(textStorage: textStorage, language: "editperfswift", font: font)

        let pasteBlock = (0..<10).map { "    let pasted\($0) = \($0) * 2\n" }.joined()
        let midpoint = (code as NSString).length / 2

        measure {
            textStorage.replaceCharacters(
                in: NSRange(location: midpoint, length: 0),
                with: pasteBlock
            )
            let editedRange = NSRange(location: midpoint, length: (pasteBlock as NSString).length)

            highlighter.highlightEdited(
                textStorage: textStorage,
                editedRange: editedRange,
                language: "editperfswift",
                font: font
            )

            textStorage.replaceCharacters(
                in: NSRange(location: midpoint, length: (pasteBlock as NSString).length),
                with: ""
            )
        }
    }

    /// Simulates rapid single-character typing (100 chars) with
    /// incremental re-highlighting after each character.
    func testRapidTypingRehighlight() {
        let code = generateCode(lines: 1000)
        let textStorage = NSTextStorage(string: code)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        highlighter.highlight(textStorage: textStorage, language: "editperfswift", font: font)

        let insertPoint = (code as NSString).length / 2

        let chars = Array("abcdefghij")

        measure {
            var offset = 0
            for i in 0..<100 {
                let char = String(chars[i % 10])
                let loc = insertPoint + offset
                textStorage.replaceCharacters(
                    in: NSRange(location: loc, length: 0),
                    with: char
                )
                highlighter.highlightEdited(
                    textStorage: textStorage,
                    editedRange: NSRange(location: loc, length: 1),
                    language: "editperfswift",
                    font: font
                )
                offset += 1
            }

            // Clean up inserted chars
            textStorage.replaceCharacters(
                in: NSRange(location: insertPoint, length: offset),
                with: ""
            )
        }
    }

    /// Tests re-highlighting after deleting a large block of text.
    func testDeleteBlockAndRehighlight() {
        let code = generateCode(lines: 2000)
        let textStorage = NSTextStorage(string: code)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        highlighter.highlight(textStorage: textStorage, language: "editperfswift", font: font)

        let midpoint = (code as NSString).length / 2
        let deleteLength = min(500, (code as NSString).length - midpoint)
        let deleted = (textStorage.string as NSString).substring(
            with: NSRange(location: midpoint, length: deleteLength)
        )

        measure {
            textStorage.replaceCharacters(
                in: NSRange(location: midpoint, length: deleteLength),
                with: ""
            )
            highlighter.highlightEdited(
                textStorage: textStorage,
                editedRange: NSRange(location: midpoint, length: 0),
                language: "editperfswift",
                font: font
            )

            // Restore deleted text
            textStorage.replaceCharacters(
                in: NSRange(location: midpoint, length: 0),
                with: deleted
            )
        }
    }
}
