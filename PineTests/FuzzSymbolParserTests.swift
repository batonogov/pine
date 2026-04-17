//
//  FuzzSymbolParserTests.swift
//  PineTests
//
//  Fuzz tests for SymbolParser: parsing, filtering, and line number resolution.
//

import Foundation
import Testing
@testable import Pine

@Suite("Fuzz Symbol Parser Tests", .timeLimit(.minutes(1)))
struct FuzzSymbolParserTests {

    @Test func fuzzSymbolParser_randomInput() {
        var rng = SplitMix64(seed: 50)
        let extensions = ["swift", "py", "js", "ts", "go", "rb", "rs", "java", "kt", "unknown"]

        for _ in 0..<200 {
            let content: String
            let ext = extensions[Int(rng.next() % UInt64(extensions.count))]

            switch rng.next() % 5 {
            case 0:
                content = FuzzGen.randomBytes(
                    count: FuzzGen.randomLength(max: 500, rng: &rng),
                    rng: &rng
                )
            case 1:
                content = FuzzGen.randomUnicode(
                    count: FuzzGen.randomLength(max: 300, rng: &rng),
                    rng: &rng
                )
            case 2:
                content = generateRandomCode(rng: &rng)
            case 3:
                content = String(repeating: "func ", count: 100)
            default:
                content = ""
            }

            // Must not crash
            _ = SymbolParser.parse(content: content, fileExtension: ext)
        }
    }

    @Test func fuzzSymbolParser_edgeCases() {
        let inputs = [
            ("", "swift"),
            ("\0\0\0", "swift"),
            (String(repeating: "\n", count: 1000), "py"),
            ("class ", "swift"),
            ("func ", "swift"),
            ("struct ", "go"),
            ("def ", "py"),
            ("function ", "js"),
            ("interface ", "ts"),
            // Deeply nested
            (String(repeating: "class A {\n", count: 50), "swift"),
            // Only comments
            (String(repeating: "// comment\n", count: 50), "swift"),
            // Only strings
            ("\"" + String(repeating: "func test() {}", count: 50) + "\"", "swift"),
        ]
        for (content, ext) in inputs {
            _ = SymbolParser.parse(content: content, fileExtension: ext)
        }
    }

    @Test func fuzzSymbolFilter_randomInput() {
        var rng = SplitMix64(seed: 51)
        let symbols = [
            PineSymbol(name: "testFunc", kind: .function, line: 1),
            PineSymbol(name: "MyClass", kind: .class, line: 5),
        ]

        for _ in 0..<200 {
            let query = FuzzGen.randomUnicode(
                count: FuzzGen.randomLength(max: 50, rng: &rng),
                rng: &rng
            )
            _ = SymbolParser.filter(symbols, query: query)
        }
    }

    @Test func fuzzLineNumber_randomInput() {
        var rng = SplitMix64(seed: 52)

        for _ in 0..<200 {
            let content = FuzzGen.randomUnicode(
                count: FuzzGen.randomLength(max: 500, rng: &rng),
                rng: &rng
            )
            let offset = Int(rng.next() % UInt64(max(1, (content as NSString).length + 10)))
            _ = SymbolParser.lineNumber(at: offset, in: content)
        }
    }

    private func generateRandomCode(rng: inout SplitMix64) -> String {
        let keywords = ["func", "class", "struct", "enum", "protocol", "def", "function", "interface", "trait", "fn"]
        var lines: [String] = []
        let count = FuzzGen.randomLength(min: 1, max: 50, rng: &rng)
        for _ in 0..<count {
            let kw = keywords[Int(rng.next() % UInt64(keywords.count))]
            let name = FuzzGen.randomPrintable(
                count: FuzzGen.randomLength(min: 1, max: 30, rng: &rng),
                rng: &rng
            )
            lines.append("  \(kw) \(name) {")
        }
        return lines.joined(separator: "\n")
    }
}
