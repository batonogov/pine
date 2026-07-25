//
//  PythonIndentationFoldTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("Python indentation folding")
struct PythonIndentationFoldTests {
    @Test("Nested declarations and controls preserve bracket folds")
    func nestedDeclarationsAndBrackets() async throws {
        let text = """
        class 类型:
            def compute(self):
                if self.ready:
                    return [
                        "值",
                    ]
                return []
        """
        let ranges = try #require(
            await localRanges(text: text, language: "python")
        )

        #expect(ranges.contains { range in
            range.startLine == 1 && range.endLine == 7
        })
        #expect(ranges.contains { range in
            range.startLine == 2 && range.endLine == 7
        })
        #expect(ranges.contains { range in
            range.startLine == 3 && range.endLine == 6
        })
        // The multiline list remains available alongside indentation folds.
        #expect(ranges.contains { range in
            range.startLine == 4
                && range.endLine == 6
                && range.kind == .brackets
        })
    }

    @Test("Blank and comment lines neither dedent nor leak past a sibling")
    func blankAndCommentLines() {
        let text = """
        class Root:
            # leading comment

            def child():
                pass

        # outside separator
        next_value = 1
        """
        let ranges = PythonIndentationFoldCalculator.calculate(
            text: text
        )

        #expect(ranges.contains { range in
            range.startLine == 1 && range.endLine == 5
        })
        #expect(ranges.contains { range in
            range.startLine == 4 && range.endLine == 5
        })
        #expect(!ranges.contains { $0.endLine >= 7 })
    }

    @Test("Mixed tabs and spaces use Python eight-column tab stops")
    func mixedIndentationCRLFAndUnicode() {
        let text = [
            "class Корень:",
            "\tdef child(self):",
            "\t \tif True:",
            "\t \t\treturn \"值\"",
            "next_value = 1"
        ].joined(separator: "\r\n")
        let ranges = PythonIndentationFoldCalculator.calculate(
            text: text
        )

        #expect(ranges.map(\.startLine) == [1, 2, 3])
        #expect(ranges.map(\.endLine) == [4, 4, 4])
        let source = text as NSString
        for range in ranges {
            #expect(range.startCharIndex < source.length)
            #expect(
                source.character(at: range.startCharIndex)
                    == 0x3A
            )
            #expect(range.endCharIndex <= source.length)
            if range.endCharIndex > 0 {
                #expect(
                    source.character(at: range.endCharIndex - 1)
                        != ASCII.carriageReturn
                )
                #expect(
                    source.character(at: range.endCharIndex - 1)
                        != ASCII.newline
                )
            }
        }
    }

    @Test("Malformed nested header cannot erase its valid enclosing suite")
    func malformedNestedHeaderRetainsOuterStructure() {
        let text = """
        class Outer:
            def broken(
                value,
            # recovery remains inside the class
            if recovery:
                work()
        next_value = 1
        """
        let ranges = PythonIndentationFoldCalculator.calculate(
            text: text
        )

        #expect(ranges.contains { range in
            range.startLine == 1 && range.endLine == 6
        })
    }

    @Test("Closed and unterminated strings cannot manufacture headers")
    func stringsDoNotCreateFalseHeaders() {
        let text = #"""
        text = """
        class Fake:
            if nope:
        """
        class Real:
            value = "# still a string"
        dangling = """
        class AlsoFake:
        """#
        let ranges = PythonIndentationFoldCalculator.calculate(
            text: text
        )

        #expect(ranges.count == 1)
        #expect(ranges[0].startLine == 5)
        #expect(ranges[0].endLine == 6)
    }

    @Test("Multiline string contents do not emit a false dedent")
    func multilineStringsDoNotDedent() {
        let text = #"""
        def render():
            value = """first
        column-zero payload
        """
            return value
        """#
        let ranges = PythonIndentationFoldCalculator.calculate(
            text: text
        )

        #expect(ranges.contains { range in
            range.startLine == 1 && range.endLine == 5
        })
    }

    @Test("A comment-only pseudo-body does not make an invalid suite")
    func commentsDoNotActivateInvalidSuite() {
        let text = """
        class Invalid:
            # comments do not emit INDENT
        next_value = 1
        """

        #expect(
            PythonIndentationFoldCalculator.calculate(text: text)
                .isEmpty
        )
    }

    @Test("Control-flow and async suite keywords are recognized")
    func controlFlowKeywords() {
        let text = """
        if ready:
            pass
        elif waiting:
            pass
        else:
            pass
        for item in items:
            pass
        while ready:
            pass
        try:
            pass
        except* Error:
            pass
        finally:
            pass
        with resource:
            pass
        match value:
            case 1:
                pass
        async def run():
            async for item in items:
                async with item:
                    pass
        """
        let ranges = PythonIndentationFoldCalculator.calculate(
            text: text
        )
        let starts = Set(ranges.map(\.startLine))

        #expect(
            Set([1, 3, 5, 7, 9, 11, 13, 15, 17, 19, 20, 22, 23, 24])
                .isSubset(of: starts)
        )
    }

    @Test("Inline suites remain single-line and are not foldable")
    func inlineSuitesAreIgnored() {
        let text = """
        if ready: run()
        class Empty: pass
        async def quick(): return 1
        """

        #expect(
            PythonIndentationFoldCalculator.calculate(text: text)
                .isEmpty
        )
    }

    @Test("Non-Python local fallback remains bracket-identical")
    func nonPythonFallbackIsUnchanged() async throws {
        let text = """
        struct Sample {
            let values = [
                1,
                2
            ]
        }
        """
        let expected = FoldRangeCalculator.calculate(text: text)
        let actual = try #require(
            await localRanges(text: text, language: "swift")
        )

        #expect(actual == expected)
    }

    @Test("Valid and malformed folding fixtures cover every LSP language")
    func initialLanguageFixtures() async throws {
        let fixtures: [LanguageFoldFixture] = [
            LanguageFoldFixture(
                language: "swift",
                fileExtension: "swift",
                valid: "struct Box {\n    let value = 1\n}",
                malformed:
                    "struct Box {\n    let unfinished =\n}",
                validEndLine: 3,
                malformedEndLine: 3
            ),
            LanguageFoldFixture(
                language: "typescript",
                fileExtension: "ts",
                valid: "class Box {\n  value = 1\n}",
                malformed:
                    "class Box {\n  unfinished =\n}",
                validEndLine: 3,
                malformedEndLine: 3
            ),
            LanguageFoldFixture(
                language: "python",
                fileExtension: "py",
                valid: "class Box:\n    value = 1\n",
                malformed:
                    "class Box:\n    def unfinished(\n        value\n",
                validEndLine: 2,
                malformedEndLine: 3
            )
        ]
        #expect(
            Set(fixtures.map(\.language))
                == Set(LanguageServerRegistry.supportedLanguages)
        )

        for fixture in fixtures {
            for (text, expectedEndLine) in [
                (fixture.valid, fixture.validEndLine),
                (fixture.malformed, fixture.malformedEndLine)
            ] {
                let ranges = try #require(
                    await localRanges(
                        text: text,
                        language: fixture.language,
                        fileExtension: fixture.fileExtension
                    )
                )
                #expect(
                    ranges.contains { range in
                        range.startLine == 1
                            && range.endLine
                            == expectedEndLine
                    },
                    "Missing \(fixture.language) fold for \(text)"
                )
            }
        }
    }

    private func localRanges(
        text: String,
        language: String,
        fileExtension: String? = nil
    ) async -> [FoldableRange]? {
        let ext = fileExtension ?? language
        let snapshot = DocumentSnapshot(
            uri: "file:///fixture.\(ext)",
            text: text,
            revision: DocumentRevision(1)
        )
        return await LocalFoldProvider(
            language: language
        ).foldRanges(for: snapshot)
    }
}

private struct LanguageFoldFixture {
    let language: String
    let fileExtension: String
    let valid: String
    let malformed: String
    let validEndLine: Int
    let malformedEndLine: Int
}
