//
//  YAMLIndentationFoldTests.swift
//  PineTests
//
//  Regression coverage for indentation-based YAML folding (#1225).
//

import Foundation
import Testing

@testable import Pine

@Suite("YAML indentation folding")
struct YAMLIndentationFoldTests {
    @Test("GitHub Actions jobs, steps, and script bodies are foldable")
    func githubActionsWorkflow() async throws {
        let text = """
        name: CI
        jobs:
          build:
            runs-on: macos-26
            steps:
              - uses: actions/checkout@v4
              - name: Test
                run: |
                  swift test
                  echo done
          lint:
            runs-on: macos-26
        """
        let ranges = try #require(
            await localRanges(text: text, language: "yaml")
        )

        #expect(indentationSpans(ranges) == [
            "2...12",
            "3...10",
            "5...10",
            "7...10",
            "8...10",
            "11...12"
        ])
    }

    @Test("A one-line body is hidden completely by indentation folds")
    func oneLineBodyUsesInclusiveEnd() throws {
        let range = try #require(
            YAMLIndentationFoldCalculator.calculate(
                text: "job:\n  runs-on: macos-26"
            ).first
        )
        #expect(range.startLine == 1)
        #expect(range.endLine == 2)
        #expect(range.kind == .indentation)

        var state = FoldState()
        state.fold(range)
        #expect(!state.isLineHidden(1))
        #expect(state.isLineHidden(2))
        #expect(state.hiddenLineCount(for: range) == 1)
    }

    @Test("Sequence items and nested mappings get independent ranges")
    func sequenceItemsAndNestedMappings() {
        let text = """
        items:
          - name: one
            value: 1
          - name: two
            nested:
              enabled: true
          - scalar
        """
        let ranges = YAMLIndentationFoldCalculator.calculate(
            text: text
        )

        #expect(indentationSpans(ranges) == [
            "1...7",
            "2...3",
            "4...6",
            "5...6"
        ])
    }

    @Test("Indentationless block sequences belong to their mapping value")
    func indentationlessSequence() {
        let text = """
        items:
        - one
        - two
        next: value
        """
        let ranges = YAMLIndentationFoldCalculator.calculate(
            text: text
        )

        #expect(indentationSpans(ranges) == ["1...3"])
    }

    @Test("Blank and comment lines do not end a block prematurely")
    func blanksAndComments() {
        let text = """
        root:
          # leading comment
          child: value

          # trailing child comment
        sibling:
          value: x
        """
        let ranges = YAMLIndentationFoldCalculator.calculate(
            text: text
        )

        #expect(indentationSpans(ranges) == [
            "1...5",
            "6...7"
        ])
    }

    @Test("A comment-only pseudo-body does not manufacture a fold")
    func commentOnlyBody() {
        let text = """
        empty:
          # no YAML node here
        sibling: value
        """

        #expect(
            YAMLIndentationFoldCalculator.calculate(text: text)
                .isEmpty
        )
    }

    @Test("A dedented trailing comment is not hidden with the prior block")
    func dedentedTrailingComment() {
        let text = """
        root:
          child: value
        # describes the next key
        next: value
        """
        let ranges = YAMLIndentationFoldCalculator.calculate(
            text: text
        )

        #expect(indentationSpans(ranges) == ["1...2"])
    }

    @Test("Quoted keys fold while URL colons and scalar items do not")
    func quotedKeysAndScalarIndicators() {
        let text = """
        "quoted:key":
          child: true
        url: https://example.com:8443/path
        values:
          - -42
          - plain
        """
        let ranges = YAMLIndentationFoldCalculator.calculate(
            text: text
        )

        #expect(indentationSpans(ranges) == [
            "1...2",
            "4...6"
        ])
    }

    @Test("Quotes and collection indicators inside plain scalars stay plain")
    func indicatorsInsidePlainScalars() async throws {
        let text = """
        title: a "quote and 'single with [bracket and {brace
        balanced: use [literal] and {literal}
        next:
          child: true
        """
        let ranges = try #require(
            await localRanges(text: text, language: "yaml")
        )

        #expect(indentationSpans(ranges) == ["3...4"])
        #expect(bracketSpans(ranges).isEmpty)
    }

    @Test("Multiline plain scalar continuation stays lexically opaque")
    func multilinePlainScalar() async throws {
        let text = """
        title: plain
          "unfinished and [bracket with {brace
        next:
          child: true
        """
        let ranges = try #require(
            await localRanges(text: text, language: "yaml")
        )

        #expect(indentationSpans(ranges) == ["3...4"])
        #expect(bracketSpans(ranges).isEmpty)
    }

    @Test("A compact mapping sibling is not plain-scalar continuation")
    func compactMappingSiblingAfterPlainValue() {
        let text = """
        - key: value
          other:
            nested: true
        """
        let ranges = YAMLIndentationFoldCalculator.calculate(
            text: text
        )

        #expect(indentationSpans(ranges) == [
            "1...3",
            "2...3"
        ])
    }

    @Test("Anchors and tags may precede nested nodes, aliases stay scalar")
    func propertiesAndAliases() {
        let text = """
        defaults: &defaults
          retries: 2
        tagged: !!map
          enabled: true
        copy: *defaults
        """
        let ranges = YAMLIndentationFoldCalculator.calculate(
            text: text
        )

        #expect(indentationSpans(ranges) == [
            "1...2",
            "3...4"
        ])
    }

    @Test("Block scalar payload is opaque to YAML and bracket folding")
    func blockScalarPayloadIsOpaque() async throws {
        let text = """
        script: |-
          echo "{"
            jobs:
          echo "}"
        next: true
        """
        let ranges = try #require(
            await localRanges(text: text, language: "yaml")
        )

        #expect(indentationSpans(ranges) == ["1...4"])
        #expect(!ranges.contains { range in
            range.kind == .braces
                || range.kind == .brackets
                || range.kind == .parentheses
        })
    }

    @Test("Folded scalar modifiers work in either valid order")
    func blockScalarModifiers() {
        let fixtures = [
            "value: >2-\n  first\n  second\nnext: true",
            "value: |-2\n  first\n  second\nnext: true",
            "value: |+\n  first\n  second\nnext: true"
        ]

        for text in fixtures {
            #expect(
                indentationSpans(
                    YAMLIndentationFoldCalculator.calculate(
                        text: text
                    )
                ) == ["1...3"]
            )
        }
    }

    @Test("Direct sequence block scalars use the sequence indentation level")
    func directSequenceBlockScalars() async throws {
        let text = """
        - |
          echo "{"
          fake:
            child: true
        - >1-
         folded [
        - done
        """
        let ranges = try #require(
            await localRanges(text: text, language: "yaml")
        )

        #expect(indentationSpans(ranges) == [
            "1...4",
            "5...6"
        ])
        #expect(bracketSpans(ranges).isEmpty)
    }

    @Test("Compact nested sequence scalars remain opaque")
    func compactNestedSequenceScalar() async throws {
        let text = """
        - - |2
            echo "["
            fake:
              child: true
        - done
        next:
          child: true
        """
        let ranges = try #require(
            await localRanges(text: text, language: "yaml")
        )

        #expect(indentationSpans(ranges) == [
            "1...4",
            "6...7"
        ])
        #expect(bracketSpans(ranges).isEmpty)
    }

    @Test("A scalar inside a compact sequence item ends before its sibling property")
    func scalarInsideSequenceItem() {
        let text = """
        - run: |
            echo hello
          shell: bash
        - run: echo done
        """
        let ranges = YAMLIndentationFoldCalculator.calculate(
            text: text
        )

        #expect(indentationSpans(ranges) == ["1...3"])
    }

    @Test("Provider exposes one canonical fold control per start line")
    func canonicalRangePerStartLine() async throws {
        let text = """
        - [
            one,
            two
          ]
        """
        let ranges = try #require(
            await localRanges(text: text, language: "yaml")
        )
        let firstLine = ranges.filter { $0.startLine == 1 }
        let range = try #require(firstLine.first)

        #expect(firstLine.count == 1)
        #expect(range.endLine == 4)
        #expect(range.kind == .indentation)
    }

    @Test("Multiline flow collections stay owned by bracket folding")
    func multilineFlowCollections() async throws {
        let text = """
        matrix: {
          os: [
            macos,
            linux
          ]
        }
        """
        let ranges = try #require(
            await localRanges(text: text, language: "yaml")
        )

        #expect(indentationSpans(ranges).isEmpty)
        #expect(bracketSpans(ranges) == [
            "1...6:braces",
            "2...5:brackets"
        ])
    }

    @Test("Explicit flow keys keep quoted indicators opaque")
    func explicitFlowKey() async throws {
        let text = """
        map: {
          ? "a, [key" : value
        }
        next:
          child: true
        """
        let ranges = try #require(
            await localRanges(text: text, language: "yaml")
        )

        #expect(indentationSpans(ranges) == ["4...5"])
        #expect(bracketSpans(ranges) == ["1...3:braces"])
    }

    @Test("Multiline quoted scalars cannot manufacture YAML structure")
    func multilineQuotedScalars() {
        let text = #"""
        message: "fake
          jobs:
            build:
        "
        single: 'also
          steps:
        '
        real:
          child: true
        """#
        let ranges = YAMLIndentationFoldCalculator.calculate(
            text: text
        )

        #expect(indentationSpans(ranges) == ["8...9"])
    }

    @Test("A document marker recovers from an unterminated quote")
    func documentMarkerRecoversLexicalState() {
        let text = #"""
        broken: "unterminated
          fake:
        ---
        real:
          child: yes
        """#
        let ranges = YAMLIndentationFoldCalculator.calculate(
            text: text
        )

        #expect(indentationSpans(ranges) == ["4...5"])
    }

    @Test("Directives and document boundaries never leak fold ranges")
    func multipleDocuments() {
        let text = """
        %YAML 1.2
        ---
        one:
          child: true
        ...
        ---
        two:
          child: true
        """
        let ranges = YAMLIndentationFoldCalculator.calculate(
            text: text
        )

        #expect(indentationSpans(ranges) == [
            "3...4",
            "7...8"
        ])
    }

    @Test("CRLF, Unicode keys, and UTF-16 offsets remain exact")
    func crlfUnicodeOffsets() throws {
        let text = "корень:\r\n  子: value\r\nnext: yes"
        let source = text as NSString
        let range = try #require(
            YAMLIndentationFoldCalculator.calculate(
                text: text
            ).first
        )

        #expect(range.startLine == 1)
        #expect(range.endLine == 2)
        #expect(
            source.character(at: range.startCharIndex)
                == 0x3A
        )
        #expect(range.endCharIndex == source.range(of: "\r\nnext").location)
        #expect(
            source.character(at: range.endCharIndex - 1)
                != ASCII.carriageReturn
        )
    }

    @Test("Malformed indentation is bounded and cannot cross a document marker")
    func malformedIndentationIsBounded() {
        let text = """
        root:
        \tchild:
        \t\tvalue: true
        ---
        next:
          value: true
        """
        let sourceLength = (text as NSString).length
        let ranges = YAMLIndentationFoldCalculator.calculate(
            text: text
        )

        #expect(ranges.allSatisfy { range in
            range.startLine >= 1
                && range.endLine <= 6
                && range.startCharIndex >= 0
                && range.endCharIndex <= sourceLength
        })
        #expect(ranges.contains { range in
            range.startLine == 5 && range.endLine == 6
        })
        #expect(!ranges.contains { range in
            range.startLine < 4 && range.endLine > 3
        })
    }

    @Test("Active depth is capped for pathological nesting")
    func activeDepthIsCapped() {
        let depth = YAMLIndentationFoldCalculator.maxActiveDepth + 25
        let lines = (0..<depth).map { index in
            String(repeating: " ", count: index)
                + "key\(index):"
        } + [
            String(repeating: " ", count: depth)
                + "value: true"
        ]
        let ranges = YAMLIndentationFoldCalculator.calculate(
            text: lines.joined(separator: "\n")
        )

        #expect(
            ranges.count
                <= YAMLIndentationFoldCalculator.maxActiveDepth
        )
    }

    @Test("Provider recognizes yaml, yml, and URI suffix fallback")
    func providerDetection() async throws {
        let text = "job:\n  child: true"
        let fixtures = [
            (language: "yaml", uri: "file:///test.txt"),
            (language: "yml", uri: "file:///test.txt"),
            (language: "plain", uri: "file:///test.yaml"),
            (language: "plain", uri: "file:///test.yml")
        ]

        for fixture in fixtures {
            let ranges = try #require(
                await localRanges(
                    text: text,
                    language: fixture.language,
                    uri: fixture.uri
                )
            )
            #expect(indentationSpans(ranges) == ["1...2"])
        }
    }

    @Test("Non-YAML fallback remains bracket-identical")
    func nonYAMLFallbackUnchanged() async throws {
        let text = "value {\n  child\n}"
        let expected = FoldRangeCalculator.calculate(text: text)
        let actual = try #require(
            await localRanges(text: text, language: "plain")
        )

        #expect(actual == expected)
    }

    @Test("Empty and single-line YAML have no fold ranges")
    func trivialInputs() {
        #expect(
            YAMLIndentationFoldCalculator.calculate(text: "")
                .isEmpty
        )
        #expect(
            YAMLIndentationFoldCalculator.calculate(
                text: "key: value"
            ).isEmpty
        )
    }

    private func localRanges(
        text: String,
        language: String,
        uri: String = "file:///fixture.yaml"
    ) async -> [FoldableRange]? {
        await LocalFoldProvider(language: language).foldRanges(
            for: DocumentSnapshot(
                uri: uri,
                text: text,
                revision: DocumentRevision(1)
            )
        )
    }

    private func indentationSpans(
        _ ranges: [FoldableRange]
    ) -> [String] {
        ranges.compactMap { range in
            guard range.kind == .indentation else { return nil }
            return "\(range.startLine)...\(range.endLine)"
        }
    }

    private func bracketSpans(
        _ ranges: [FoldableRange]
    ) -> [String] {
        ranges.compactMap { range in
            let kind: String
            switch range.kind {
            case .braces:
                kind = "braces"
            case .brackets:
                kind = "brackets"
            case .parentheses:
                kind = "parentheses"
            case .indentation:
                return nil
            }
            return "\(range.startLine)...\(range.endLine):\(kind)"
        }
    }
}
